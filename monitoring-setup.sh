
# ---------------------------------------------------------
# FINAL STATUS AND LOGIN CREDENTIALS
# ---------------------------------------------------------
echo
echo "======================================================"
echo "       EKS MONITORING INSTALLATION SUMMARY"
echo "======================================================"

echo
echo "--------------- GRAFANA ------------------------------"

if kubectl get secret monitoring-grafana \
    -n monitoring >/dev/null 2>&1; then

  GRAFANA_USER="admin"
  GRAFANA_PASSWORD="$(
    kubectl get secret monitoring-grafana \
      -n monitoring \
      -o jsonpath='{.data.admin-password}' | base64 -d
  )"

  GRAFANA_LB="$(
    kubectl get svc monitoring-grafana \
      -n monitoring \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' \
      2>/dev/null || true
  )"

  echo "Username : ${GRAFANA_USER}"
  echo "Password : ${GRAFANA_PASSWORD}"

  if [[ -n "$GRAFANA_LB" ]]; then
    echo "URL      : http://${GRAFANA_LB}"
  else
    echo "URL      : Grafana LoadBalancer hostname not available."
    echo "Check    : kubectl get svc monitoring-grafana -n monitoring"
  fi
else
  echo "Grafana Secret not found."
  echo "Check    : kubectl get secrets -n monitoring"
fi

echo
echo "--------------- CLICKHOUSE --------------------------"

CH_PASSWORD="$(
  kubectl get secret clickhouse-client-secret \
    -n monitoring \
    -o jsonpath='{.data.password}' | base64 -d
)"

CH_LB="$(
  kubectl get svc clickhouse-eks-test-lb \
    -n monitoring \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' \
    2>/dev/null || true
)"

echo "Username          : default"
echo "Password          : ${CH_PASSWORD}"

if [[ -n "$CH_LB" ]]; then
  echo "HTTP URL          : http://${CH_LB}:8123"
  echo "Native TCP Host   : ${CH_LB}:9000"
else
  echo "LoadBalancer      : Pending or unavailable."
  echo "Check             : kubectl get svc -n monitoring"
fi

echo
echo "--------------- INSTALLATION STATUS -----------------"
kubectl get pods -n monitoring
kubectl get svc -n monitoring

echo
echo "IMPORTANT: Store these credentials securely."
echo "======================================================"
