# Dashboards: Kubernetes

Grafana folder **Kubernetes**. Two sources land there:

- **Official** - the ~27 dashboards kube-prometheus-stack 93.3.0 ships (kubernetes-mixin, node-exporter-mixin, etcd,
  CoreDNS, Prometheus, Alertmanager, Grafana). The folder comes from `grafana.sidecar.dashboards.annotations`
  (`grafana_folder: Kubernetes`) in `helm-charts/monitoring/kube-prometheus-stack/values.yaml.gotmpl`; the annotation is
  global to the chart, so the Prometheus/Alertmanager/Grafana ones land here too (curated versions of those live in
  *Observability*).
- **Curated** - three dashboards in `helm-charts/monitoring/monitoring-raw/dashboards/kubernetes/` (ConfigMaps
  `dashboard-kubernetes-<name>`), built for a single node:

| File | UID | Title | Answers |
|---|---|---|---|
| `cluster-health.json` | `hl-kubernetes-cluster-health` | Cluster health: node & capacity | Is k8s01 healthy, how much CPU/memory/disk/network headroom is left, which pods are pending, crash-looping, OOM-killed? |
| `control-plane.json` | `hl-kubernetes-control-plane` | Control plane | Is the API server meeting its SLO, is etcd healthy, are the scheduler/controller-manager/kube-proxy working, when do certificates expire? |
| `addons.json` | `hl-kubernetes-addons` | Cluster add-ons | CoreDNS, metrics-server, kubelet-csr-approver, local-path-provisioner, kube-state-metrics/node-exporter and scrape targets. |

Every curated dashboard has a "How to read this dashboard" text panel, a description on every panel (meaning, normal vs
bad, formula source) and thresholds taken from the upstream alert that watches the same signal. All queries were checked
with `scripts/check-dashboard.py` against the live Prometheus (0 errors; EMPTY results listed below).

Main formula sources: [kubernetes-mixin](https://github.com/kubernetes-monitoring/kubernetes-mixin) (rules, alerts,
dashboards), [node-exporter mixin](https://github.com/prometheus/node_exporter/tree/master/docs/node-mixin),
[etcd mixin](https://github.com/etcd-io/etcd/tree/main/contrib/mixin), [coredns-mixin](https://github.com/povilasv/coredns-mixin),
[kps dashboards](https://github.com/prometheus-community/helm-charts/tree/kube-prometheus-stack-93.3.0/charts/kube-prometheus-stack/templates/grafana/dashboards-1.14),
[Kubernetes metrics reference](https://kubernetes.io/docs/reference/instrumentation/metrics/),
[kube-state-metrics docs](https://github.com/kubernetes/kube-state-metrics/tree/main/docs/metrics). The recording rules
loaded here (kps `defaultRules`) are reused wherever they exist: `instance:node_*` (node-exporter.rules),
`node_namespace_pod_container:*` and `namespace_{cpu,memory}:*` (k8s.rules), `apiserver_request:*`,
`code_resource:apiserver_request_total:rate5m`, `cluster_quantile:apiserver_request_sli_duration_seconds:histogram_quantile`
(kube-apiserver rules), `cluster_quantile:scheduler_*` (kube-scheduler.rules),
`node_quantile:kubelet_pleg_relist_duration_seconds:histogram_quantile` (kubelet.rules).

## Official kube-prometheus-stack dashboards (kept)

All kept: they are the upstream reference and cost nothing. The single-cluster `cluster` variable has no values; Grafana
renders it empty and the queries still work. Evaluation for this single node (EMPTY counts from check-dashboard):

| Dashboard | Verdict here | Expected-empty panels |
|---|---|---|
| Kubernetes / Compute Resources / Cluster, Namespace (Pods/Workloads), Pod, Workload, Node (Pods) | **Useful**: drill-down per namespace/pod (CPU, memory, network, storage IO). | CPU quota/limits/throttling (no CPU limits by design) |
| Kubernetes / Compute Resources / Multi-Cluster, Nodes Overview | Noise (one cluster, one node). | - |
| Kubernetes / Networking / Cluster, Namespace (Pods/Workload), Pod, Workload | Useful for "who sends traffic". | - |
| Kubernetes / API server | Useful (availability/error budget per verb, detailed). | - |
| Kubernetes / Kubelet | Useful for deep kubelet issues. | config errors, storage operation errors, 3xx (none happen) |
| Kubernetes / Scheduler, Controller Manager, Proxy | Low value day to day (mostly client RPC rates); curated *Control plane* covers the signals. | `scheduler_volume_scheduling_*` (removed upstream), 3xx/4xx/5xx client RPC series (none) |
| Kubernetes / Persistent Volumes | **Misleading here**: local PVs report the whole root filesystem, hostPath PVs report nothing (see Storage). | - |
| etcd | Useful (DB size, fsync, gRPC). | peer traffic / peer RTT (single member) |
| CoreDNS | **Useful**, detailed view; the curated add-ons row has the critical subset + alert thresholds. | DO-bit requests (no DNSSEC clients) |
| Node Exporter / Nodes, USE Method / Node, USE Method / Cluster | Useful node detail (per-CPU, per-device). | network drops (none) |
| Prometheus / Overview, Alertmanager / Overview, Grafana Overview | Belong to Observability; kept as reference. | Grafana "Firing Alerts" (no Grafana-managed alerts) |

AIX and macOS node dashboards are disabled (`nodeExporter.operatingSystems`); Windows ones are not rendered (no Windows
node). kps has no per-dashboard toggle for Multi-Cluster/Nodes Overview, so they stay.

## Curated: Cluster health: node & capacity (`cluster-health.json`)

Rows and panels (source of each formula in the panel description):

- **Status** - Node Ready, Node pressure (KubeNodeNotReady / KubeNodePressure), Schedulable (cordon), Uptime, Firing
  alerts (warning|critical), Pod slots used (KubeletTooManyPods, 95 %), Pending pods, CrashLoopBackOff (KubePodCrashLooping).
- **CPU** - utilisation gauge (`instance:node_cpu_utilisation:rate5m`, NodeCPUHighUsage 90 %), load per CPU
  (`instance:node_load1_per_cpu:ratio`, NodeSystemSaturation 2), CPU requests vs allocatable
  (`namespace_cpu:kube_pod_container_resource_requests:sum`, KubeCPUOvercommit), CPU PSI, cores, a "CPU limits present"
  counter (instead of throttling panels, which are empty by design), CPU by namespace (recording rule), saturation over time.
- **Memory** - utilisation gauge (`instance:node_memory_utilisation:ratio`, NodeMemoryHighUtilization 90 %), memory
  requests vs allocatable, memory PSI, major page faults (NodeMemoryMajorPagesFaults 500/s), kernel OOM kills 24 h
  (`node_vmstat_oom_kill`), working set by namespace, node memory breakdown (node-mixin "Memory Usage").
- **Disk & storage** - root FS used (node-mixin filesystem alert thresholds 85/95/97 %), free bytes, predicted free in
  24 h (`predict_linear(...[6h], 24h)`, NodeFilesystemSpaceFillingUp), inodes, PVC requests vs disk size, free + projection
  over time, disk I/O utilisation/queue (`instance_device:node_disk_io_time*`, NodeDiskIOSaturation 10), throughput + I/O
  PSI, top disk writers by pod (cAdvisor `container_fs_writes_bytes_total`), PVC table (requested size, StorageClass, PV).
- **Network** - NIC (`en*|eth*|wl*` = enp3s0) throughput, errors/drops, conntrack usage (NodeHighNumberConntrackEntriesUsed 75 %).
- **Pods & workloads** - pods by phase, restarts by namespace, containers restarted 1 h, failed Jobs (KubeJobFailed),
  pods not healthy (the two KubePodNotReady conditions), containers waiting with reason, OOM-killed containers
  (`kube_pod_container_status_last_terminated_reason` + cgroup `container_oom_events_total`), most restarted 24 h,
  **Kubernetes Warning events** (Loki, `service_name="k8s-events"`, PolicyViolation filtered out).
- **Kubelet & hardware** - kubelet up, PLEG p99 (KubeletPlegDurationHigh 10 s), pod worker p99
  (KubeletPodStartUpLatencyHigh 60 s), CRI operation errors, hwmon temperatures (coretemp), clock offset/sync
  (NodeClockSkewDetected 50 ms).

Annotations: firing warning/critical alerts, container restarts (`changes(kube_pod_container_status_restarts_total[2m]) > 0`),
kernel OOM kills (`increase(node_vmstat_oom_kill[2m]) > 0`), node reboots (`changes(node_boot_time_seconds[5m]) > 0`).

## Curated: Control plane (`control-plane.json`)

- **Status** - API server, etcd, scheduler, controller-manager, kube-proxy up; etcd leader; API availability 30 d
  (`apiserver_request:availability30d{verb="all"}`, SLO 99 %); error budget left = (availability - 0.99) / 0.01
  (the mixin "ErrorBudget (30d)" panel expressed as a share of the budget).
- **kube-apiserver** - requests by code and 5xx ratio (`code_resource:apiserver_request_total:rate5m`), p99 latency per
  verb (histogram recording rule, SLO 1 s line), burn rate 1 h/6 h (`apiserver_request:burnrate*`, KubeAPIErrorBudgetBurn
  14.4 % / 6 %), in-flight + APF queued, APF rejected 1 h, terminated requests (KubeAPITerminatedRequests 20 %),
  aggregated APIs unavailable (KubeAggregatedAPIDown) and their errors (KubeAggregatedAPIErrors), API server -> etcd p99
  (`etcd_request_duration_seconds`), objects stored top 10 (`apiserver_resource_objects`).
- **etcd** - DB size, DB vs quota (etcdDatabaseQuotaLowSpace 95 %), DB in-use ratio (fragmentation; neutral colour because
  etcdDatabaseHighFragmentationRatio needs > 100 MB in use - today ~42 MB of a 154 MB file), leader changes 24 h, failed
  proposals, memory, WAL fsync + backend commit p99 (etcdHighFsyncDurations 0.5/1 s, etcdHighCommitDurations 0.25 s),
  size vs quota over time, proposals committed/pending + gRPC failure ratio (etcdHighNumberOfFailedGRPCRequests 1/5 %).
- **Scheduler & controller-manager** - leader status (`leader_election_master_status`), unschedulable pods, scheduling
  SLI p99 (recording rule), control-plane client 5xx (`rest_client_requests_total`), scheduler errors, scheduler queues
  (`scheduler_pending_pods`), attempts by result, controller-manager workqueue depth top 10.
- **kube-proxy** - rule changes waiting (last queued - last sync, IPv4; red at 60 s = kube-proxy healthz timeout of
  2x syncPeriod), rules sync and network programming p99, iptables rules per table.
- **Certificates** - kubelet serving and client cert TTL (KubeletServer/ClientCertificateExpiration 7 d / 1 d), shortest
  client cert seen by the API server (KubeClientCertificateExpiration formula over 1 h; the histogram tops out at 1 year),
  kubelet renewal errors.
- **Resource usage** - CPU and working-set memory per kube-system pod.

Annotations: control-plane alerts (KubeAPI*, KubeClient*, KubeAggregatedAPI*, KubeScheduler*, KubeControllerManager*,
KubeProxy*, Kubelet*Certificate*, etcd*), kube-system container restarts, etcd leader changes.

## Curated: Cluster add-ons (`addons.json`)

Decision on the tiny services: **one shared dashboard, one row each** instead of a dashboard per service. metrics-server
exports ~12 own metric names, kubelet-csr-approver only generic controller-runtime metrics, local-path-provisioner none;
a dedicated dashboard each would be mostly empty, while together they answer one question ("are the cluster's helper
services OK?"). CoreDNS gets a row with the critical signals and alert thresholds; the official kps CoreDNS dashboard
stays for detail (it has no thresholds and no upstream view, which is why the row exists).

- **CoreDNS** - up, queries/s, SERVFAIL ratio (CoreDNSErrorsHigh 1/3 %), p99 latency (CoreDNSLatencyHigh 4 s), cache hit
  ratio, forward healthcheck broken, panics, reload failures, responses by rcode, p50/p99 latency, upstream p99 + SERVFAIL
  per resolver (`coredns_proxy_request_duration_seconds{proxy_name="forward"}`).
- **metrics-server** - up, `v1beta1.metrics.k8s.io` APIService availability, kubelet scrape success ratio, last scrape
  age (`timestamp(m) - m` so the 1 min Prometheus scrape interval does not inflate it; red at 60 s = 4 x the 15 s
  metric-resolution), containers in store, scrape/freshness/tick p99.
- **kubelet-csr-approver** - up, leader, kubelet serving cert TTL (its purpose), pending CSRs
  (`kube_certificatesigningrequest_condition`), reconciles/errors in the selected range, kubelet server renewal errors,
  non-2xx API answers.
- **local-path-provisioner** - deployment ready, restarts, PVCs Pending, PVs Failed/Pending/Released
  (KubePersistentVolumeErrors), PV count, free root FS, PVs by volume type (`local` vs `hostPath`), **PVC events** and
  **provisioner logs** from Loki.
- **Telemetry agents** - table of every Kubernetes scrape target (up, duration, samples), kube-state-metrics list/watch
  error ratios (KubeStateMetricsListErrors/WatchErrors 1 %), node-exporter textfile errors, memory of kube-state-metrics
  and node-exporter.

Annotations: CoreDNS/aggregated API/kube-state-metrics/kubelet cert/PV/TargetDown alerts, restarts of the four add-on
pods, CoreDNS reload failures (`increase(coredns_reload_failed_total[2m]) > 0`).

## Services and the metrics they export here

Counts are metric names / series at the time of writing.

### kube-apiserver (job `apiserver`, 448 names, ~81k series)
Static pod, scraped over https with the Prometheus ServiceAccount token. Families: `apiserver_request_*`
(total by verb/code/resource, duration/SLI/SLO histograms - the SLO is built on `apiserver_request_sli_duration_seconds`),
`apiserver_flowcontrol_*` (API Priority and Fairness: executing/in-queue/rejected per priority level),
`apiserver_current_inflight_requests`, `apiserver_request_terminations_total`, `aggregator_unavailable_apiservice*`
(aggregated APIs), `etcd_request_*` (API server -> etcd latency/errors), `apiserver_resource_objects` (objects per type),
`apiserver_storage_size_bytes`, `apiserver_watch_*` and `apiserver_watch_cache_*`, `apiserver_admission_*` (webhooks:
Kyverno), `authentication_*`/`authorization_*`, `apiserver_client_certificate_expiration_seconds`, `rest_client_*`, Go runtime.
It is ~29 % of all series; see the relabeling change below.

### etcd (job `kube-etcd`, 195 names)
Plain http on :2381 (metrics listener set on the host by homelab-ansible). Important: `etcd_server_has_leader`,
`etcd_server_leader_changes_seen_total`, `etcd_server_proposals_{committed,applied,pending,failed}*`,
`etcd_mvcc_db_total_size_in_bytes` / `_in_use_in_bytes`, `etcd_server_quota_backend_bytes`,
`etcd_disk_wal_fsync_duration_seconds`, `etcd_disk_backend_commit_duration_seconds`, `grpc_server_handled_total`
(by method/code), `etcd_network_client_grpc_*`. `etcd_debugging_*` (60 names) are internal. **Missing**:
`grpc_server_handling_seconds_*` (needs `--metrics=extensive`), so the mixin alert etcdGRPCRequestsSlow can never fire,
and peer metrics (single member).

### kube-scheduler (job `kube-scheduler`) and kube-controller-manager (job `kube-controller-manager`)
https :10259/:10257. Scheduler: `scheduler_pending_pods{queue}`, `scheduler_unschedulable_pods{plugin}`,
`scheduler_schedule_attempts_total{result}`, `scheduler_pod_scheduling_sli_duration_seconds`,
`scheduler_scheduling_attempt_duration_seconds`, plugin/preemption histograms. Controller-manager: `workqueue_*` per
controller, `endpoint_slice_*`, `node_collector_*`, `job_controller_*`, `root_ca_cert_publisher_*`. Both:
`leader_election_master_status`, `rest_client_*`, Go runtime.

### kube-proxy (job `kube-proxy`, iptables mode)
http :10249. `kubeproxy_sync_proxy_rules_{duration_seconds,last_timestamp_seconds,last_queued_timestamp_seconds}`
(per `ip_family`; IPv6 is unused and syncs hourly), `kubeproxy_network_programming_duration_seconds`,
`kubeproxy_sync_proxy_rules_iptables_total{table}`, `*_endpoint_changes_*`, `*_service_changes_*`, conntrack reconciler.

### kubelet + cAdvisor (job `kubelet`, paths `/metrics`, `/metrics/cadvisor`, `/metrics/probes`)
kubelet: `kubelet_running_pods/containers`, `kubelet_pleg_relist_*`, `kubelet_pod_worker_duration_seconds`,
`kubelet_pod_start_sli_duration_seconds`, `kubelet_runtime_operations_*`, `kubelet_certificate_manager_{server,client}_ttl_seconds`,
`kubelet_server_expiration_renew_errors`, `kubelet_volume_stats_*` (only for `local` PVs - see Storage), `storage_operation_*`.
cAdvisor: `container_cpu_*`, `container_memory_{working_set,rss,cache,swap}_bytes`, `container_oom_events_total`,
`container_fs_{reads,writes}*` (no `container_fs_usage_bytes` with containerd), `container_network_*`, `machine_*`.

### CoreDNS (job `coredns`, 1.14.6)
`coredns_dns_requests_total`, `coredns_dns_responses_total{rcode}`, `coredns_dns_request_duration_seconds`,
request/response sizes, `coredns_cache_{entries,hits_total,requests_total}`, `coredns_proxy_request_duration_seconds{proxy_name="forward",to,rcode}`
(upstreams: the LAN router and a public resolver), `coredns_forward_healthcheck_broken_total`,
`coredns_forward_max_concurrent_rejects_total`, `coredns_panics_total`, `coredns_reload_failed_total`,
`coredns_kubernetes_*`, `coredns_health_*`. Cache hit ratio is low (~5 %): most queries are unique search-path
lookups; informational only.

### kube-state-metrics (job `kube-state-metrics`, 185 names, ~8.7k series)
Object state from the API: `kube_pod_*` (phase, ready, container waiting/terminated reasons, restarts, requests/limits),
`kube_node_*` (conditions, capacity/allocatable, unschedulable), `kube_deployment_*`, `kube_statefulset_*`,
`kube_daemonset_*`, `kube_job_*`, `kube_cronjob_*`, `kube_persistentvolume*`, `kube_certificatesigningrequest_*`
(only while CSRs exist), `kube_lease_*`. Self-metrics (`kube_state_metrics_list_total`, `_watch_total`) were not scraped
before this change.

### node-exporter (job `node-exporter`, 335 names)
`node_cpu_seconds_total`, `node_load*`, `node_pressure_*` (PSI cpu/memory/io), `node_memory_*` (no swap configured),
`node_vmstat_{pgmajfault,oom_kill}`, `node_filesystem_*` (`/` ext4 on /dev/sda2, `/boot/efi`), `node_disk_*` (sda),
`node_network_*` (NIC enp3s0 plus cali*/vxlan virtual devices), `node_nf_conntrack_*`, `node_hwmon_temp_*` (coretemp),
`node_thermal_zone_temp`, `node_timex_*`, `node_boot_time_seconds`, `node_textfile_scrape_error`. Several collectors
report `node_scrape_collector_success == 0` because the hardware/feature is absent (bcachefs, bonding, nfs, nvme, rapl,
zfs, ...), and `conntrack` (the netlink stats part; `node_nf_conntrack_entries` works): harmless, not alerted.

### metrics-server (job `metrics-server`)
`metrics_server_kubelet_request_total{success}`, `metrics_server_kubelet_request_duration_seconds`,
`metrics_server_kubelet_last_request_time_seconds`, `metrics_server_api_metric_freshness_seconds`,
`metrics_server_manager_tick_duration_seconds`, `metrics_server_storage_points{type}`, plus generic apiserver/rest_client.
Resolution 15 s, kubelet TLS verified (no `--kubelet-insecure-tls`).

### kubelet-csr-approver (job `kubelet-csr-approver`)
Only generic controller-runtime metrics: `controller_runtime_reconcile_total{result}`, `_reconcile_errors_total`,
`workqueue_*`, `leader_election_master_status`, `rest_client_requests_total{code}`, `certwatcher_*`. No CSR-specific
counter; the outcome is watched through the kubelet serving certificate TTL and kube-state-metrics CSR metrics.

### local-path-provisioner
No metrics endpoint (upstream has none). Watched through kube-state-metrics (deployment, PV/PVC phases), Loki logs and
PVC events.

### Storage: what "PVC usage" means on this node
local-path PVs are directories under `/opt/local-path-provisioner` on the root filesystem. For PVs of type `local`
(created since `defaultVolumeType: local`; 5 PVs today) kubelet reports `kubelet_volume_stats_*` as the statfs of the whole
root filesystem (capacity = 234 GB for every PVC). For `hostPath` PVs (5 older PVs: Prometheus, Alertmanager, Grafana,
Loki, Tempo) it reports nothing. Requested PVC sizes are not enforced. Therefore the real limit is the root filesystem
(Cluster health, Disk row); the kps "Persistent Volumes" dashboard and KubePersistentVolumeFillingUp effectively measure `/`.

## EMPTY panels (expected)

| Dashboard | Panel | Why |
|---|---|---|
| Cluster health | Container restarts by namespace | No restart in the current 5 m window (shows bars over a time range). |
| Cluster health | Pods not healthy (A, B) | No Pending/Unknown/Failed pods, none Running-but-not-Ready. |
| Cluster health | Containers waiting | No container waiting. |
| Cluster health | OOM-killed containers (A, B) | No OOMKilled termination / cgroup OOM event in 24 h. |
| Cluster health | Container runtime operation errors | No CRI errors (filtered `> 0`). |
| Control plane | In-flight and queued requests, series B | APF queues empty (filtered `> 0`). |
| Control plane | Controller-manager work queues | All queues at 0 (filtered `> 0`). |
| Add-ons | kube-state-metrics list/watch errors | **Pending scrape**: series appear once `kube-state-metrics.selfMonitor` is synced. |

Stats over counters that only exist after the first event use `or vector(0)` and show 0 (APF rejected, terminated
requests, SERVFAIL ratio, CrashLoopBackOff, failed Jobs, pending CSRs...).

## Changes in `helm-charts/monitoring/kube-prometheus-stack/values.yaml.gotmpl`

- `kube-state-metrics.selfMonitor.enabled: true` - scrapes the telemetry port 8081 (same ServiceMonitor, endpoint
  `metrics`, job stays `kube-state-metrics`). Without it KubeStateMetricsListErrors/WatchErrors can never fire.
  Pending scrape: check `kube_state_metrics_list_total` and `kube_state_metrics_watch_total` after sync.
- `kubeApiServer.serviceMonitor.metricRelabelings` - keeps the chart default bucket drop and additionally drops six
  apiserver histograms that no rule or dashboard here uses (`apiserver_watch_events_dispatch_duration_seconds`,
  `apiserver_watch_list_duration_seconds`, `apiserver_storage_list_duration_seconds`, `apiserver_request_body_size_bytes`,
  `apiserver_watch_cache_read_wait_seconds`, `apiserver_watch_cache_initialization_duration_seconds` `_bucket`):
  ~34k series (~12 % of the head). `apiserver_request_duration_seconds_bucket` is kept (used by the platform KEDA dashboard).
- `additionalPrometheusRulesMap.coredns` from `coredns.rules.yaml` - the coredns-mixin alerts (CoreDNSDown,
  LatencyHigh, ErrorsHigh, ForwardLatencyHigh, ForwardErrorsHigh, ForwardHealthcheckFailureCount/BrokenCount);
  kube-prometheus-stack ships none for CoreDNS. Forward rules use the `coredns_proxy_*{proxy_name="forward"}`
  replacements documented by CoreDNS for the deprecated `coredns_forward_*` metrics.

## Gaps and recommendations

- **etcd gRPC latency** (Ansible, homelab-ansible): add `--metrics=extensive` to the etcd static pod so
  `grpc_server_handling_seconds_*` exists; today etcdGRPCRequestsSlow cannot fire.
- **kubeadm control-plane certificates** (apiserver, etcd, front-proxy, admin.conf) are not visible to Prometheus. Either
  check `kubeadm certs check-expiration` from Ansible on a schedule, or deploy an x509 certificate exporter reading
  `/etc/kubernetes/pki` (needs a hostPath DaemonSet: a Kyverno exception). They renew with every `kubeadm upgrade`.
- **KubePersistentVolumeFillingUp** fires once per `local` PVC when `/` fills, on top of NodeFilesystem* (same cause,
  ~6 alerts). Acceptable; if it gets noisy, disable it via `defaultRules.disabled`.
- **Old hostPath PVs** (Prometheus, Alertmanager, Grafana, Loki, Tempo) are skipped by Velero file-system backup;
  recreating them as `local` PVs would make them backup-able (a data migration, owner's call).
- **Per-PV disk usage** is not measurable with the current exporters; if needed, a textfile collector running `du` on
  `/opt/local-path-provisioner/*` (node-exporter textfile, set up by Ansible) would give it.
- Worth adding later: an alert on `kubeproxy` rule changes not applied > 60 s (the dashboard shows it; the kube-proxy
  liveness probe already restarts it in the worst case).
- Pre-existing render warning (not from this change): `alertmanager-kps` Secret with literal data is the chart-generated
  Alertmanager config; it contains no credential.
