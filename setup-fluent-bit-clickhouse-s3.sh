#!/usr/bin/env bash
set -Eeuo pipefail

AWS_ACCOUNT_ID="555552813318"
AWS_REGION="us-east-1"
CLUSTER_NAME="test-cluster"
NAMESPACE="monitoring"
SERVICE_ACCOUNT="fluent-bit"
IAM_ROLE_NAME="fluent-bit-s3-role"
BUCKET_NAME="logs-store-bucket-555552813318-us-east-1-an"
CLICKHOUSE_HOST="a6ad54349fa61442fb4a8ccf56d171b3-2087361601.us-east-1.elb.amazonaws.com"
CLICKHOUSE_PORT="8123"
CLICKHOUSE_USER="admin"

say() { printf '\n========== %s ==========\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Required command missing: $1"; }

for c in aws kubectl helm eksctl curl python3; do need "$c"; done
python3 -c 'import yaml' >/dev/null 2>&1 || die "Install PyYAML: apt-get update && apt-get install -y python3-yaml"

say "Checking AWS identity"
CURRENT_ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
[[ "$CURRENT_ACCOUNT" == "$AWS_ACCOUNT_ID" ]] || die "Wrong AWS account: $CURRENT_ACCOUNT"

say "Updating kubeconfig and checking EKS"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"
kubectl get nodes

read -r -s -p "Enter ClickHouse HTTP password for ${CLICKHOUSE_USER}: " CLICKHOUSE_PASSWORD
printf '\n'
[[ -n "$CLICKHOUSE_PASSWORD" ]] || die "ClickHouse password is empty."

say "Verifying ClickHouse endpoint and credentials"
CH_RESPONSE="$(curl -sS --connect-timeout 5 --max-time 15 \
  -u "${CLICKHOUSE_USER}:${CLICKHOUSE_PASSWORD}" \
  "http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}/" \
  --data-binary 'SELECT 1' || true)"
[[ "$CH_RESPONSE" == "1" ]] || die "ClickHouse check failed: ${CH_RESPONSE}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
VALUES_FILE="${TMP_DIR}/fluent-bit-values.yaml"

say "Ensuring S3 bucket and encryption"
if ! aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  aws s3api create-bucket --bucket "$BUCKET_NAME" \
    --bucket-namespace account-regional --region "$AWS_REGION" \
    || die "Could not create or access S3 bucket."
fi

aws s3api put-public-access-block --bucket "$BUCKET_NAME" --region "$AWS_REGION" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-encryption --bucket "$BUCKET_NAME" --region "$AWS_REGION" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

say "Associating EKS OIDC provider"
eksctl utils associate-iam-oidc-provider \
  --cluster "$CLUSTER_NAME" --region "$AWS_REGION" --approve

OIDC_ISSUER="$(aws eks describe-cluster --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" --query 'cluster.identity.oidc.issuer' --output text)"
[[ "$OIDC_ISSUER" == https://oidc.eks."${AWS_REGION}".amazonaws.com/id/* ]] \
  || die "Unexpected OIDC issuer: ${OIDC_ISSUER}"

OIDC_PROVIDER="${OIDC_ISSUER#https://}"
ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${IAM_ROLE_NAME}"

cat > "${TMP_DIR}/trust-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_PROVIDER}:sub": "system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT}",
        "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
EOF

cat > "${TMP_DIR}/s3-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::${BUCKET_NAME}"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"],
      "Resource": "arn:aws:s3:::${BUCKET_NAME}/*"
    }
  ]
}
EOF

say "Creating or updating IAM role"
if aws iam get-role --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$IAM_ROLE_NAME" \
    --policy-document "file://${TMP_DIR}/trust-policy.json"
else
  aws iam create-role --role-name "$IAM_ROLE_NAME" \
    --assume-role-policy-document "file://${TMP_DIR}/trust-policy.json" \
    --description "IRSA role for Fluent Bit S3 archive"
fi

aws iam put-role-policy --role-name "$IAM_ROLE_NAME" \
  --policy-name fluent-bit-s3 --policy-document "file://${TMP_DIR}/s3-policy.json"

say "Checking namespace and service account"
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  echo "Namespace monitoring exists; reusing it."
else
  kubectl create namespace "$NAMESPACE"
fi

if kubectl -n "$NAMESPACE" get serviceaccount "$SERVICE_ACCOUNT" >/dev/null 2>&1; then
  echo "Service account already exists; reusing it."
else
  kubectl -n "$NAMESPACE" create serviceaccount "$SERVICE_ACCOUNT"
fi

kubectl -n "$NAMESPACE" annotate serviceaccount "$SERVICE_ACCOUNT" \
  "eks.amazonaws.com/role-arn=${ROLE_ARN}" --overwrite

cat > "${TMP_DIR}/fluent-bit-rbac.yaml" <<'RBAC_EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: fluent-bit-events-reader
rules:
  - apiGroups: [""]
    resources: ["events", "pods", "namespaces"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: fluent-bit-events-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: fluent-bit-events-reader
subjects:
  - kind: ServiceAccount
    name: fluent-bit
    namespace: monitoring
RBAC_EOF

kubectl apply -f "${TMP_DIR}/fluent-bit-rbac.yaml"

say "Generating Fluent Bit Helm values"
cat > "$VALUES_FILE" <<'VALUES_EOF'
serviceAccount:
  create: false
  name: fluent-bit

config:
  inputs: |
    [INPUT]
        Name              tail
        Path              /var/log/containers/*.log
        Exclude_Path      /var/log/containers/chi-*_monitoring_*.log
        multiline.parser  docker, cri
        Tag               kube.*
        Mem_Buf_Limit     50MB
        Skip_Long_Lines   On
        Refresh_Interval  10
        storage.type      filesystem

    [INPUT]
        Name              kubernetes_events
        Tag               k8s_events
        Kube_URL          https://kubernetes.default.svc
        Kube_CA_File      /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        Kube_Token_File   /var/run/secrets/kubernetes.io/serviceaccount/token
        interval_sec      30
        db                /var/log/flb_k8s_events.db

  filters: |
    [FILTER]
        Name                kubernetes
        Match               kube.*
        Kube_URL            https://kubernetes.default.svc:443
        Kube_CA_File        /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        Kube_Token_File     /var/run/secrets/kubernetes.io/serviceaccount/token
        Kube_Tag_Prefix     kube.var.log.containers.
        Merge_Log           On
        K8S-Logging.Parser  On
        K8S-Logging.Exclude Off
        Labels              On

    [FILTER]
        Name         nest
        Match        kube.*
        Operation    lift
        Nested_under kubernetes
        Add_prefix   k8s_

    [FILTER]
        Name    modify
        Match   kube.*
        Rename  log                 message
        Rename  k8s_container_name  container
        Rename  k8s_pod_name        pod_name
        Rename  k8s_namespace_name  namespace

    [FILTER]
        Name         nest
        Match        k8s_events
        Operation    lift
        Nested_under involvedObject
        Add_prefix   involved_

    [FILTER]
        Name    modify
        Match   k8s_events
        Rename  involved_name        pod_name
        Rename  involved_namespace   namespace
        Rename  involved_kind        object_kind
        Rename  type                 event_type

  outputs: |
    [OUTPUT]
        Name                          s3
        Match                         kube.*
        bucket                        CHANGE_BUCKET
        region                        CHANGE_REGION
        total_file_size               10M
        upload_timeout                1m
        s3_key_format                 /pod-logs/year=%Y/month=%m/day=%d/hour=%H/minute=%M/pod-logs-$UUID.gz
        s3_key_format_tag_delimiters  .
        store_dir_limit_size          5G
        use_put_object                On
        compression                   gzip
        Retry_Limit                   5

    [OUTPUT]
        Name                          s3
        Match                         k8s_events
        bucket                        CHANGE_BUCKET
        region                        CHANGE_REGION
        total_file_size               10M
        upload_timeout                1m
        s3_key_format                 /k8s-events/year=%Y/month=%m/day=%d/hour=%H/minute=%M/events-$UUID.json.gz
        s3_key_format_tag_delimiters  .
        store_dir_limit_size          2G
        use_put_object                On
        compression                   gzip
        Retry_Limit                   5

    [OUTPUT]
        Name             http
        Match            kube.*
        Host             CHANGE_CLICKHOUSE_HOST
        Port             CHANGE_CLICKHOUSE_PORT
        URI              /?query=INSERT%20INTO%20observability.logs%20FORMAT%20JSONEachRow&input_format_skip_unknown_fields=1&date_time_input_format=best_effort
        Format           json
        HTTP_User        CHANGE_CLICKHOUSE_USER
        HTTP_Passwd      CHANGE_CLICKHOUSE_PASSWORD
        json_date_key    timestamp
        json_date_format iso8601
        tls              Off
        Retry_Limit      5

    [OUTPUT]
        Name             http
        Match            k8s_events
        Host             CHANGE_CLICKHOUSE_HOST
        Port             CHANGE_CLICKHOUSE_PORT
        URI              /?query=INSERT%20INTO%20observability.k8s_events%20FORMAT%20JSONEachRow&input_format_skip_unknown_fields=1&date_time_input_format=best_effort
        Format           json
        HTTP_User        CHANGE_CLICKHOUSE_USER
        HTTP_Passwd      CHANGE_CLICKHOUSE_PASSWORD
        json_date_key    timestamp
        json_date_format iso8601
        tls              Off
        Retry_Limit      5

  service: |
    [SERVICE]
        Flush         5
        Daemon        Off
        Log_Level     info
        Parsers_File  parsers.conf
        HTTP_Server   On
        HTTP_Listen   0.0.0.0
        HTTP_Port     2020
        storage.path  /var/log/flb-storage/

tolerations:
  - operator: Exists
VALUES_EOF

python3 - "$VALUES_FILE" "$BUCKET_NAME" "$AWS_REGION" "$CLICKHOUSE_HOST" \
  "$CLICKHOUSE_PORT" "$CLICKHOUSE_USER" "$CLICKHOUSE_PASSWORD" <<'PY'
import pathlib, sys
import yaml

p = pathlib.Path(sys.argv[1])
text = p.read_text()
replacements = {
    "CHANGE_BUCKET": sys.argv[2],
    "CHANGE_REGION": sys.argv[3],
    "CHANGE_CLICKHOUSE_HOST": sys.argv[4],
    "CHANGE_CLICKHOUSE_PORT": sys.argv[5],
    "CHANGE_CLICKHOUSE_USER": sys.argv[6],
    "CHANGE_CLICKHOUSE_PASSWORD": sys.argv[7],
}
for old, new in replacements.items():
    text = text.replace(old, new)

yaml.safe_load(text)
p.write_text(text)
print("Helm values YAML validated.")
PY

say "Validating Helm chart"
helm repo add fluent https://fluent.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update

helm template fluent-bit fluent/fluent-bit \
  --namespace "$NAMESPACE" --values "$VALUES_FILE" \
  > "${TMP_DIR}/rendered.yaml" \
  || die "Helm could not render the values file."

if grep -q 'CHANGE_BUCKET' "${TMP_DIR}/rendered.yaml"; then
  die "Unreplaced placeholder found in rendered configuration."
fi

say "Checking existing Helm release"
if helm -n "$NAMESPACE" status fluent-bit >/dev/null 2>&1; then
  echo "Release exists; upgrading it."
else
  echo "Release does not exist; installing it."
fi

say "Installing or upgrading Fluent Bit in monitoring"
helm upgrade --install fluent-bit fluent/fluent-bit \
  --namespace "$NAMESPACE" --values "$VALUES_FILE" \
  --wait --timeout 5m

say "Waiting for DaemonSet rollout"
if ! kubectl -n "$NAMESPACE" rollout status daemonset/fluent-bit --timeout=180s; then
  kubectl -n "$NAMESPACE" get pods -o wide || true
  POD="$(kubectl -n "$NAMESPACE" get pods \
    -l app.kubernetes.io/name=fluent-bit \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$POD" ]]; then
    kubectl -n "$NAMESPACE" logs "$POD" \
      --all-containers=true --tail=100 || true
  fi
  die "Fluent Bit rollout failed. Review the errors above."
fi

say "Installation complete"
kubectl -n "$NAMESPACE" get pods -o wide

echo
echo "Check Fluent Bit logs:"
echo "kubectl -n monitoring logs daemonset/fluent-bit --tail=80"
echo
echo "Check archived pod logs:"
echo "aws s3 ls s3://${BUCKET_NAME}/pod-logs/ --recursive | tail"
echo
echo "Check archived Kubernetes events:"
echo "aws s3 ls s3://${BUCKET_NAME}/k8s-events/ --recursive | tail"
echo
echo "Confirm ClickHouse tables observability.logs and observability.k8s_events exist."
