#!/usr/bin/env python3
import json, logging, os, ssl, sys, time, urllib.parse, urllib.request
from datetime import datetime, timezone

log = logging.getLogger("inventory")
API = os.environ.get("K8S_API", "https://kubernetes.default.svc")
SA = "/var/run/secrets/kubernetes.io/serviceaccount"
CH_URL = os.environ.get("CH_URL", "http://localhost:8123")
CH_USER = os.environ.get("CH_USER", "default")
CH_PASS = os.environ.get("CH_PASSWORD", "")
PROM_URL = os.environ.get("PROM_URL", "http://monitoring-kube-prometheus-prometheus.monitoring.svc:9090")
INTERVAL = int(os.environ.get("INTERVAL_SECONDS", "60"))
DEDICATED_LABELS = [x.strip() for x in os.environ.get("DEDICATED_LABEL_KEYS", "dedicated,workload-type").split(",") if x.strip()]
SYSTEM_TAINT_PREFIXES = ("node.kubernetes.io/", "node.cloudprovider.kubernetes.io/")
NODEGROUP_LABELS = ["eks.amazonaws.com/nodegroup", "alpha.eksctl.io/nodegroup-name",
                    "karpenter.sh/nodepool", "nodegroup", "node-group"]
CAPACITY_LABELS = ["eks.amazonaws.com/capacityType", "karpenter.sh/capacity-type"]
CTX = None


def cpu_m(q):
    if q is None:
        return 0
    s = str(q)
    if s.endswith("m"):
        return int(float(s[:-1]))
    if s.endswith("u"):
        return int(float(s[:-1]) / 1000)
    if s.endswith("n"):
        return int(float(s[:-1]) / 1e6)
    return int(float(s) * 1000)


_BIN = {"Ki": 1024, "Mi": 1024**2, "Gi": 1024**3, "Ti": 1024**4, "Pi": 1024**5, "Ei": 1024**6}
_DEC = {"k": 1000, "K": 1000, "M": 1000**2, "G": 1000**3, "T": 1000**4, "P": 1000**5, "E": 1000**6}


def mem_b(q):
    if q is None:
        return 0
    s = str(q)
    for suf, mul in _BIN.items():
        if s.endswith(suf):
            return int(float(s[:-2]) * mul)
    if s and s[-1] in _DEC:
        return int(float(s[:-1]) * _DEC[s[-1]])
    if s.endswith("m"):
        return int(float(s[:-1]) / 1000)
    return int(float(s))


def ts_str(epoch):
    return datetime.fromtimestamp(epoch, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def iso_str(s):
    return s.replace("T", " ").rstrip("Z")[:19] if s else "1970-01-01 00:00:00"


def kget(path):
    token = open(f"{SA}/token").read().strip()
    req = urllib.request.Request(API + path, headers={"Authorization": "Bearer " + token, "Accept": "application/json"})
    with urllib.request.urlopen(req, context=CTX, timeout=60) as r:
        return json.load(r)


def klist(path):
    items, cont = [], ""
    while True:
        q = "limit=500" + ("&continue=" + urllib.parse.quote(cont) if cont else "")
        d = kget(path + "?" + q)
        items += d.get("items", [])
        cont = d.get("metadata", {}).get("continue", "")
        if not cont:
            return items


def prom_vector(query):
    url = PROM_URL + "/api/v1/query?" + urllib.parse.urlencode({"query": query})
    try:
        with urllib.request.urlopen(url, timeout=30) as r:
            return json.load(r)["data"]["result"]
    except Exception as e:
        log.warning("prometheus query failed (%s): %s", query[:60], e)
        return []


def ch_insert(table, rows):
    if not rows:
        return
    params = urllib.parse.urlencode({
        "query": f"INSERT INTO observability.{table} FORMAT JSONEachRow",
        "input_format_skip_unknown_fields": 1,
        "date_time_input_format": "best_effort",
    })
    body = "\n".join(json.dumps(r) for r in rows).encode()
    req = urllib.request.Request(CH_URL + "/?" + params, data=body,
                                 headers={"X-ClickHouse-User": CH_USER, "X-ClickHouse-Key": CH_PASS})
    with urllib.request.urlopen(req, timeout=60) as r:
        r.read()


def owner_maps(replicasets, jobs):
    def ctrl(o):
        refs = o["metadata"].get("ownerReferences") or []
        ref = next((r for r in refs if r.get("controller")), None)
        return (ref["kind"], ref["name"]) if ref else None
    rs = {(o["metadata"]["namespace"], o["metadata"]["name"]): ctrl(o) for o in replicasets}
    jb = {(o["metadata"]["namespace"], o["metadata"]["name"]): ctrl(o) for o in jobs}
    return rs, jb


def pod_owner(pod, rs_owner, job_owner):
    md = pod["metadata"]
    refs = md.get("ownerReferences") or []
    ref = next((r for r in refs if r.get("controller")), refs[0] if refs else None)
    if not ref:
        return "Pod", md["name"]
    kind, name, ns = ref["kind"], ref["name"], md["namespace"]
    if kind == "ReplicaSet" and rs_owner.get((ns, name)):
        return rs_owner[(ns, name)]
    if kind == "Job" and job_owner.get((ns, name)):
        return job_owner[(ns, name)]
    return kind, name


def pod_state(pod):
    st = pod.get("status", {})
    phase = st.get("phase", "Unknown")
    if pod["metadata"].get("deletionTimestamp"):
        return "Terminating"
    for c in st.get("conditions", []):
        if c.get("type") == "PodScheduled" and c.get("status") == "False":
            return "Unschedulable"
    for cs in st.get("initContainerStatuses", []) + st.get("containerStatuses", []):
        w = (cs.get("state") or {}).get("waiting")
        if w and w.get("reason") not in (None, "PodInitializing", "ContainerCreating"):
            return w["reason"]
    if phase == "Running":
        ready = all(c.get("ready") for c in st.get("containerStatuses", []))
        return "Running" if ready else "NotReady"
    return phase


def last_term_reason(pod):
    for cs in pod.get("status", {}).get("containerStatuses", []):
        t = (cs.get("lastState") or {}).get("terminated")
        if t and t.get("reason"):
            return t["reason"]
    return ""


def pod_resources(pod):
    req_c = req_m = lim_c = lim_m = 0
    unl_c = unl_m = False
    for c in pod["spec"].get("containers", []):
        r = (c.get("resources") or {})
        rq, lm = r.get("requests") or {}, r.get("limits") or {}
        req_c += cpu_m(rq.get("cpu")); req_m += mem_b(rq.get("memory"))
        if "cpu" in lm: lim_c += cpu_m(lm["cpu"])
        else: unl_c = True
        if "memory" in lm: lim_m += mem_b(lm["memory"])
        else: unl_m = True
    return req_c, (0 if unl_c else lim_c), req_m, (0 if unl_m else lim_m)


def build_pod_rows(pods, rs_owner, job_owner, cpu_use, mem_use, ts):
    rows = []
    for p in pods:
        md, sp = p["metadata"], p["spec"]
        kind, name = pod_owner(p, rs_owner, job_owner)
        rc, lc, rm, lm = pod_resources(p)
        key = (md["namespace"], md["name"])
        rows.append({
            "ts": ts, "namespace": md["namespace"], "pod": md["name"], "node": sp.get("nodeName", ""),
            "pod_ip": p.get("status", {}).get("podIP", ""), "host_ip": p.get("status", {}).get("hostIP", ""),
            "state": pod_state(p), "last_term_reason": last_term_reason(p),
            "restarts": sum(c.get("restartCount", 0) for c in p.get("status", {}).get("containerStatuses", [])),
            "workload_kind": kind, "workload": name, "qos": p.get("status", {}).get("qosClass", ""),
            "created": iso_str(md.get("creationTimestamp")),
            "cpu_req_m": rc, "cpu_lim_m": lc, "mem_req_b": rm, "mem_lim_b": lm,
            "cpu_use_m": round(cpu_use.get(key, 0.0), 1), "mem_use_b": int(mem_use.get(key, 0)),
            "containers": len(sp.get("containers", [])),
        })
    return rows


def build_node_rows(nodes, pod_rows, node_cpu, node_mem, ts):
    sched = {}
    for r in pod_rows:
        if r["node"] and r["state"] not in ("Succeeded", "Failed"):
            sched[r["node"]] = sched.get(r["node"], 0) + 1
    rows = []
    for n in nodes:
        md, st, sp = n["metadata"], n.get("status", {}), n.get("spec", {})
        labels = md.get("labels", {})
        addr = {a["type"]: a["address"] for a in st.get("addresses", [])}
        taints = [f'{t["key"]}={t.get("value", "")}:{t["effect"]}' for t in (sp.get("taints") or [])]
        custom_taint = any(not t["key"].startswith(SYSTEM_TAINT_PREFIXES) for t in (sp.get("taints") or []))
        dedicated = custom_taint or any(k in labels for k in DEDICATED_LABELS)
        ready = any(c["type"] == "Ready" and c["status"] == "True" for c in st.get("conditions", []))
        alloc = st.get("allocatable", {})
        ip = addr.get("InternalIP", "")
        rows.append({
            "ts": ts, "node": md["name"], "internal_ip": ip, "external_ip": addr.get("ExternalIP", ""),
            "instance_type": labels.get("node.kubernetes.io/instance-type", ""),
            "zone": labels.get("topology.kubernetes.io/zone", ""),
            "nodegroup": next((labels[k] for k in NODEGROUP_LABELS if k in labels), ""),
            "capacity_type": next((labels[k] for k in CAPACITY_LABELS if k in labels), ""),
            "node_class": "dedicated" if dedicated else "shared",
            "is_tainted": 1 if taints else 0, "taints": taints,
            "ready": 1 if ready else 0, "unschedulable": 1 if sp.get("unschedulable") else 0,
            "cpu_alloc_m": cpu_m(alloc.get("cpu")), "mem_alloc_b": mem_b(alloc.get("memory")),
            "pods_alloc": int(alloc.get("pods", 0)), "pods_scheduled": sched.get(md["name"], 0),
            "cpu_used_pct": round(node_cpu.get(ip, 0.0), 1), "mem_used_pct": round(node_mem.get(ip, 0.0), 1),
            "kubelet_version": st.get("nodeInfo", {}).get("kubeletVersion", ""),
            "os_image": st.get("nodeInfo", {}).get("osImage", ""), "labels": labels,
        })
    return rows


def build_workload_rows(deploys, stss, dss, ts):
    rows = []
    def images(o):
        return [c["image"] for c in o["spec"]["template"]["spec"].get("containers", [])]
    for o in deploys:
        s = o.get("status", {})
        rows.append(dict(ts=ts, namespace=o["metadata"]["namespace"], name=o["metadata"]["name"], kind="Deployment",
                         desired=o["spec"].get("replicas", 1), ready=s.get("readyReplicas", 0),
                         available=s.get("availableReplicas", 0), updated=s.get("updatedReplicas", 0), images=images(o)))
    for o in stss:
        s = o.get("status", {})
        rows.append(dict(ts=ts, namespace=o["metadata"]["namespace"], name=o["metadata"]["name"], kind="StatefulSet",
                         desired=o["spec"].get("replicas", 1), ready=s.get("readyReplicas", 0),
                         available=s.get("availableReplicas", s.get("readyReplicas", 0)),
                         updated=s.get("updatedReplicas", 0), images=images(o)))
    for o in dss:
        s = o.get("status", {})
        rows.append(dict(ts=ts, namespace=o["metadata"]["namespace"], name=o["metadata"]["name"], kind="DaemonSet",
                         desired=s.get("desiredNumberScheduled", 0), ready=s.get("numberReady", 0),
                         available=s.get("numberAvailable", 0), updated=s.get("updatedNumberScheduled", 0), images=images(o)))
    return rows


def collect_once():
    ts = ts_str(time.time())
    nodes = klist("/api/v1/nodes")
    pods = klist("/api/v1/pods")
    rsets = klist("/apis/apps/v1/replicasets")
    jobs = klist("/apis/batch/v1/jobs")
    deploys = klist("/apis/apps/v1/deployments")
    stss = klist("/apis/apps/v1/statefulsets")
    dss = klist("/apis/apps/v1/daemonsets")
    sel = 'container!="",container!="POD"'
    cpu = {(r["metric"].get("namespace", ""), r["metric"].get("pod", "")): float(r["value"][1]) * 1000
           for r in prom_vector(f'sum by (namespace,pod)(rate(container_cpu_usage_seconds_total{{{sel}}}[2m]))')}
    mem = {(r["metric"].get("namespace", ""), r["metric"].get("pod", "")): float(r["value"][1])
           for r in prom_vector(f'sum by (namespace,pod)(container_memory_working_set_bytes{{{sel}}})')}
    ncpu = {r["metric"]["instance"].split(":")[0]: float(r["value"][1])
            for r in prom_vector('100*(1-avg by (instance)(rate(node_cpu_seconds_total{mode="idle"}[2m])))')}
    nmem = {r["metric"]["instance"].split(":")[0]: float(r["value"][1])
            for r in prom_vector('100*(1-node_memory_MemAvailable_bytes/node_memory_MemTotal_bytes)')}
    rs_owner, job_owner = owner_maps(rsets, jobs)
    pod_rows = build_pod_rows(pods, rs_owner, job_owner, cpu, mem, ts)
    node_rows = build_node_rows(nodes, pod_rows, ncpu, nmem, ts)
    wl_rows = build_workload_rows(deploys, stss, dss, ts)
    ch_insert("node_inventory", node_rows)
    ch_insert("pod_inventory", pod_rows)
    ch_insert("deployment_inventory", wl_rows)
    log.info("snapshot %s: %d nodes, %d pods, %d workloads", ts, len(node_rows), len(pod_rows), len(wl_rows))


def main():
    global CTX
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    CTX = ssl.create_default_context(cafile=f"{SA}/ca.crt")
    while True:
        start = time.time()
        try:
            collect_once()
        except Exception as e:
            log.error("snapshot failed: %s", e)
        time.sleep(max(1, INTERVAL - (time.time() - start)))


if __name__ == "__main__":
    sys.exit(main())
