CREATE DATABASE IF NOT EXISTS observability;

CREATE TABLE IF NOT EXISTS observability.logs
(
    timestamp  DateTime64(3) DEFAULT now64(3),
    namespace  LowCardinality(String),
    pod_name   String,
    container  LowCardinality(String),
    node       LowCardinality(String),
    stream     LowCardinality(String),
    message    String CODEC(ZSTD(3))
)
ENGINE = MergeTree
PARTITION BY toDate(timestamp)
ORDER BY (namespace, pod_name, timestamp)
TTL toDateTime(timestamp) + INTERVAL 7 DAY
SETTINGS ttl_only_drop_parts = 1;

CREATE TABLE IF NOT EXISTS observability.k8s_events
(
    timestamp    DateTime64(3) DEFAULT now64(3),
    namespace    LowCardinality(String),
    pod_name     String,
    reason       LowCardinality(String),
    message      String,
    event_type   LowCardinality(String),
    object_kind  LowCardinality(String)
)
ENGINE = MergeTree
PARTITION BY toDate(timestamp)
ORDER BY (namespace, pod_name, timestamp)
TTL toDateTime(timestamp) + INTERVAL 7 DAY
SETTINGS ttl_only_drop_parts = 1;

CREATE TABLE IF NOT EXISTS observability.node_inventory
(
    ts DateTime, node LowCardinality(String), internal_ip String, external_ip String,
    instance_type LowCardinality(String), zone LowCardinality(String), nodegroup LowCardinality(String),
    capacity_type LowCardinality(String), node_class LowCardinality(String), is_tainted UInt8,
    taints Array(String), ready UInt8, unschedulable UInt8, cpu_alloc_m UInt32, mem_alloc_b UInt64,
    pods_alloc UInt16, pods_scheduled UInt16, cpu_used_pct Float32, mem_used_pct Float32,
    kubelet_version LowCardinality(String), os_image String, labels Map(String, String)
)
ENGINE = MergeTree PARTITION BY toDate(ts) ORDER BY (ts, node)
TTL ts + INTERVAL 14 DAY SETTINGS ttl_only_drop_parts = 1;

CREATE TABLE IF NOT EXISTS observability.pod_inventory
(
    ts DateTime, namespace LowCardinality(String), pod String, node LowCardinality(String),
    pod_ip String, host_ip String, state LowCardinality(String), last_term_reason LowCardinality(String),
    restarts UInt32, workload_kind LowCardinality(String), workload String, qos LowCardinality(String),
    created DateTime, cpu_req_m UInt32, cpu_lim_m UInt32, mem_req_b UInt64, mem_lim_b UInt64,
    cpu_use_m Float32, mem_use_b UInt64, containers UInt8
)
ENGINE = MergeTree PARTITION BY toDate(ts) ORDER BY (ts, namespace, pod)
TTL ts + INTERVAL 14 DAY SETTINGS ttl_only_drop_parts = 1;

CREATE TABLE IF NOT EXISTS observability.deployment_inventory
(
    ts DateTime, namespace LowCardinality(String), name String, kind LowCardinality(String),
    desired UInt32, ready UInt32, available UInt32, updated UInt32, images Array(String)
)
ENGINE = MergeTree PARTITION BY toDate(ts) ORDER BY (ts, namespace, name)
TTL ts + INTERVAL 14 DAY SETTINGS ttl_only_drop_parts = 1;

CREATE VIEW IF NOT EXISTS observability.node_latest AS
SELECT * FROM observability.node_inventory WHERE ts = (SELECT max(ts) FROM observability.node_inventory);

CREATE VIEW IF NOT EXISTS observability.pod_latest AS
SELECT * FROM observability.pod_inventory WHERE ts = (SELECT max(ts) FROM observability.pod_inventory);

CREATE VIEW IF NOT EXISTS observability.deployment_latest AS
SELECT * FROM observability.deployment_inventory WHERE ts = (SELECT max(ts) FROM observability.deployment_inventory);
