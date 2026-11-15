# Dashboards: GitOps & Platform

Grafana folder **GitOps & Platform** (`helm-charts/monitoring/monitoring-raw/dashboards/platform/`). Services: Argo CD,
KEDA, Velero. Every dashboard has a reading guide at the top, a description on each panel (with the source of the
query) and annotations for firing alerts and container restarts of the service namespace.

| Dashboard (uid) | Kind | File |
|-----------------|------|------|
| Argo CD / Operations (`hl-platform-argocd-ops`) | curated | `argocd-ops.json` |
| Argo CD / Official (`hl-platform-argocd`) | official, adapted | `argocd.json` |
| KEDA / Operations (`hl-platform-keda-ops`) | curated | `keda-ops.json` |
| KEDA / Official (`hl-platform-keda`) | official, adapted | `keda.json` |
| Velero / Backups (`hl-platform-velero-ops`) | curated | `velero-ops.json` |
| Velero / Official (`hl-platform-velero`) | community (Velero project), trimmed | `velero.json` |

Validation: `scripts/check-dashboard.py` against the live Prometheus, 0 errors on every file (EMPTY results are listed
per dashboard below). The JSON files are generated from small scripts kept outside the repo; edit the JSON directly.

---

## Argo CD

**What it does here.** Argo CD v3.6.1 (chart argo-cd 10.18.0, namespace `argo`, `fullnameOverride: argo-cd`) deploys
every app from `main`: the ApplicationSet `platform` creates one Application per app (22 today, all in AppProject
`platform`), the repo-server renders them with the helmfile CMP sidecar (`helmfile-plugin`), the controller polls git
every 15–25 s and auto-syncs with self-heal. Redis is the chart's in-memory cache.

**Scrape jobs** (chart ServiceMonitors): `argo-cd-application-controller-metrics` (:8082),
`argo-cd-applicationset-controller-metrics` (:8080), `argo-cd-repo-server-metrics` (:8084), `argo-cd-server-metrics`
(:8083). Reference: <https://github.com/argoproj/argo-cd/blob/v3.6.1/docs/operator-manual/metrics.md>.

### Metrics that matter

| Family | Metrics | Meaning / use |
|--------|---------|---------------|
| App state | `argocd_app_info{sync_status,health_status,phase,autosync_enabled,dest_namespace}` | one series per app = 1; the basis of "out of sync / not healthy" and of the repo alerts |
| App conditions | `argocd_app_condition{name,condition}` | **pending scrape**: enabled by this change for ComparisonError, SyncError, InvalidSpecError |
| Syncs | `argocd_app_sync_total{name,phase}`, `argocd_app_sync_duration_seconds_total` | finished syncs per phase (Succeeded/Error/Failed…); total sync seconds |
| Reconciliation | `argocd_app_reconcile` (histogram), `workqueue_*{name=app_reconciliation_queue|app_operation_processing_queue|…}` | compare latency; backlog of the controller |
| K8s API | `argocd_app_k8s_request_total`, `argocd_kubectl_requests_total{code}`, `argocd_kubectl_request_duration_seconds`, `argocd_kubectl_exec_pending/_total{command}` | API traffic and errors; kubectl apply/auth queue. `argocd_kubectl_exec_total` has no result label, so "kubectl errors" are read from `argocd_kubectl_requests_total` codes and sync phases |
| Cluster cache | `argocd_cluster_connection_status`, `argocd_cluster_api_resource_objects`, `argocd_cluster_api_resources`, `argocd_cluster_events_total`, `argocd_cluster_cache_age_seconds` | connectivity, cache size (drives controller memory), watch events |
| Repo-server | `grpc_server_handled_total{grpc_method="GenerateManifest",grpc_code}`, `argocd_git_request_total/_duration_seconds{request_type=ls-remote|fetch}`, `argocd_git_lsremote_fail_total`, `argocd_git_fetch_fail_total`, `argocd_repo_pending_request_total`, `argocd_repo_parallelism_wait_duration_seconds` | render results (non-OK code = helmfile failure), git polling, render queue |
| Render latency | `grpc_server_handling_seconds{grpc_method="GenerateManifest"}` | **pending scrape**: needs `ARGOCD_ENABLE_GRPC_TIME_HISTOGRAM=true` (set by this change) |
| Redis (client side) | `argocd_redis_request_total{initiator,failed}`, `argocd_redis_request_duration` (controller/server) and `argocd_redis_request_duration_seconds` (repo-server) | cache failures/latency |
| API server | `grpc_server_handled_total{job=argo-cd-server-metrics}`, `argocd_login_request_total{status}`, `argocd_info{version}` | UI/CLI/MCP errors, logins |
| ApplicationSet | `argocd_appset_info`, `argocd_appset_owned_applications`, `argocd_appset_reconcile`, `controller_runtime_*` | generator health |
| Runtime | `go_*`, `process_*`, `certwatcher_*` | standard Go/process metrics |

Redis has no exporter (`redis.metrics.enabled: false`). Decision: not worth adding — it is a cache without persistence,
and the client-side `argocd_redis_request_*` metrics already show failures and latency for every component.

### Argo CD / Operations (curated)

Rows and formula sources (A = Argo CD docs v3.6.1, D = official dashboard, R = repo alerts, G = go-grpc-prometheus
semantics, K = kubernetes-mixin, W = client-go workqueue metrics):
- **Is GitOps converging?** Applications (D), Out of sync (R `ArgoAppNotSynced`, D), Not healthy (R `ArgoAppUnhealthy`),
  Progressing (D), Sync failures 24 h (D), Render errors 24 h (G, derived: non-OK GenerateManifest), Cluster connection
  (A), Version (A); **Applications** table with colour-coded sync/health/last operation; Apps with error conditions
  (A, pending scrape); apps by health / by sync status (D).
- **Syncs**: operations by app, failures by app/phase (D), average sync duration (A, derived: duration_total / sync_total).
- **Application controller**: reconcile p50/p95/p99 (D histogram as quantiles), reconciliations/s (D), workqueue depth
  (D, W), workqueue wait p95 (W), pending kubectl (D), API non-2xx (A; 404 mostly normal), API p95 (A), cluster cache (D).
- **Repo server**: renders by gRPC code (G, D), render latency (A, G, pending scrape), render queue (A), git requests and
  p95 (D), git failures (A, `or vector(0)` because the counters appear on first failure), Redis requests/latency (D, A).
- **API server and ApplicationSet**: API errors by service (D, G), logins (A), ApplicationSet reconcile p95 + owned apps (A).
- **Resources**: memory vs limit, CPU (K). The controller was OOMKilled at 1 GiB (limit now 3 GiB).

Annotations: firing alerts and restarts in `argo`, every finished sync (`changes(argocd_app_sync_total[2m])`).
EMPTY at validation: *Sync failures by app* (no failure in the window), *Manifest render latency* ×2 and *Apps with error
conditions* (pending scrape), *Logins* (counter only exists after the first login handled by the current API server Pod).

### Argo CD / Official

Source: <https://github.com/argoproj/argo-cd/blob/v3.6.1/examples/dashboard.json> (tag = installed version). Kept for
the full internals (per-gRPC-service rows, telemetry per component). Changes: `job="argocd-*"` → `job="argo-cd-*"`
(our fullnameOverride; upstream jobs would match nothing), namespace variable regex `.*argocd.*` removed (it hid our
namespace `argo`) and default `argo`, interval default 5m, datasource fixed, homelab annotations, reading guide,
generated descriptions for panels that had none, duplicate upstream panel ids renumbered. Noisy for this lab:
multi-cluster panels (one cluster), per-gRPC-service rows (mostly idle). Legacy `graph` panels are auto-migrated by
Grafana. EMPTY: *Operations* (no operation running), *Sync Failures* (none in the window).

---

## KEDA

**What it does here.** KEDA 2.21.0 (namespace `keda`): operator, metrics API server (`external.metrics.k8s.io`),
admission webhooks, one replica each. **No ScaledObject/ScaledJob exists yet.**

**Scrape jobs**: `keda-operator` (:8080), `keda-operator-metrics-apiserver` (:8080), `keda-admission-webhooks` (:8080).
Reference: <https://keda.sh/docs/2.21/integrations/prometheus/>.

| Family | Metrics | Meaning / use |
|--------|---------|---------------|
| Build | `keda_build_info{version}` | only KEDA metric present without scalers (documented) |
| Scalers (appear with ScaledObjects) | `keda_scaler_active`, `keda_scaler_metrics_value`, `keda_scaler_metrics_latency_seconds`, `keda_scaler_detail_errors_total`, `keda_scaler_empty_upstream_responses_total`, `keda_scaled_object_errors_total`, `keda_scaled_job_errors_total`, `keda_scaled_object_paused`, `keda_internal_scale_loop_latency_seconds`, `keda_resource_registered_total`, `keda_trigger_registered_total`, `keda_scaler_http_*`, `keda_grpc_client_*` | scaler health and the values fed to the HPA |
| Operator ↔ metrics server | `keda_internal_metricsservice_grpc_server_*` (operator), `keda_internal_metricsservice_grpc_client_*` (metrics server) | internal gRPC; appear once an HPA queries a ScaledObject |
| Webhooks | `controller_runtime_webhook_requests_total{webhook,code}`, `keda_webhook_scaled_object_validation_total/_errors` | CR validation |
| Controllers | `controller_runtime_reconcile_*{controller=scaledobject|scaledjob|triggerauthentication|clustertriggerauthentication|cloudeventsource|clustercloudeventsource|cert-rotator}`, `workqueue_*`, `leader_election_master_status`, `rest_client_requests_total`, `certwatcher_read_certificate_*` | operator health; KEDA rotates its own TLS certs |
| Metrics API server | `apiserver_request_total`, `apiserver_request_duration_seconds` and the rest of the embedded apiserver library metrics | what the HPA controller sees |

### KEDA / Operations (curated)
- **Is KEDA up?** `up` per component, APIService `v1beta1.external.metrics.k8s.io` availability
  (`aggregator_unavailable_apiservice`), version, leader, KEDA-managed HPAs (`kube_horizontalpodautoscaler_info` with the
  `keda-hpa-` prefix used by the official dashboard), reconcile errors 24 h, certificate read errors 24 h.
- **Operator**: reconciliations by result, errors by controller, workqueue depth, reconcile p95 (controller-runtime),
  API responses by component.
- **Metrics API server**: requests by code, p95 by verb (Kubernetes apiserver metrics), gRPC calls to the operator (KEDA docs).
- **Admission webhooks**: requests by code, rejected ScaledObjects.
- **Scalers** (all from the KEDA docs / official dashboard): errors, ScaledObject/ScaledJob errors, metric value, latency,
  scale loop lag, active/paused.
- **Resources**: memory vs limit, CPU.

EMPTY at validation (all expected while no ScaledObject exists): reconciliations by result (no reconcile in the window),
gRPC calls to the operator, webhook requests (no CR applied), the 8 scaler queries.

### KEDA / Official
Source: <https://github.com/kedacore/keda/blob/v2.21.0/config/grafana/keda-dashboard.json>. Changes: datasource,
annotations, guide, descriptions. Every panel and variable is empty until a ScaledObject exists (documented KEDA
behaviour) — kept because it becomes the per-ScaledObject view as soon as one is created.

---

## Velero

**What it does here.** Velero 1.18.2 (chart 12.2.5, namespace `velero`): schedule `velero-daily` at 03:00 UTC, TTL 720 h,
namespaces `vault`, `keycloak`, `dependency-track`; objects + **Kopia file-system backup** by the node-agent (no
snapshots: local-path) to Cloudflare R2; one Kopia repository per namespace with maintenance Jobs. At the time of writing
only three manual smoke-test backups exist (one PartiallyFailed); the schedule's first run is the next 03:00 UTC.

**Scrape jobs**: `velero` (server, ServiceMonitor :8085), `velero/node-agent` (PodMonitor). Reference:
<https://github.com/vmware-tanzu/velero/blob/v1.18.2/pkg/metrics/metrics.go>.

| Family | Metrics | Meaning / use |
|--------|---------|---------------|
| Backup results | `velero_backup_attempt/success/partial_failure/failure/validation_failure/warning_total{schedule}` | counters per schedule; initialised to 0 for every schedule at startup, `schedule=""` = manual backups |
| Freshness | `velero_backup_last_successful_timestamp{schedule}`, `velero_backup_last_status{schedule}` | last success (rebuilt from Backup objects on startup); last status 1/0 — **initialised to 1 at startup**, read it with the age |
| Content | `velero_backup_items_total`, `velero_backup_items_errors`, `velero_backup_tarball_size_bytes`, `velero_backup_duration_seconds` (histogram) | per schedule; the tarball holds Kubernetes objects only, Kopia volume data has no size metric |
| Inventory | `velero_backup_total`, `velero_restore_total` | existing Backup / Restore objects |
| Storage | `velero_backup_location_status_gauge{backup_location_name}` | 1 = BSL available |
| Deletion / restore | `velero_backup_deletion_*_total`, `velero_restore_*_total` | TTL expiry, restores |
| Kopia maintenance | `velero_repo_maintenance_success/failure_total{repository_name}`, `velero_repo_maintenance_duration_seconds` | maintenance Jobs (failure counter appears on first failure) |
| Node-agent | `podVolume_pod_volume_backup_enqueue/dequeue_count{node}`, `podVolume_pod_volume_operation_latency_seconds(_gauge)` | file-system backups; the latency series appear after the first FSB handled by the current node-agent Pod |
| Unused here | `velero_volume_snapshot_*`, `velero_csi_snapshot_*`, `podVolume_data_upload/download_*` | snapshots / CSI data mover, not used (no snapshots) |
| Kopia internals | `kopia_*` (job `velero`) | exported by the Velero server only while it has a Kopia repository open; sporadic, not used in dashboards |

### Velero / Backups (curated, default range 7 days)
- **Is the last backup good?** last successful age per schedule (green < 25 h, red ≥ 36 h = alert `VeleroBackupStale`),
  age of any backup, last status per schedule, BSL availability, failed backups 7 d (failure + partial + validation),
  backups stored.
- **Backup runs**: results per day (16829 "Backup per hour" with 1 d buckets), average duration per day (derived:
  `increase(_sum[1d]) / increase(_count[1d])`), items/item errors, warnings, tarball size (objects only).
- **Volume data**: FSB enqueued vs dequeued per hour (16829), in flight (derived: enqueue − dequeue), volume copy time per
  PodVolumeBackup (16829 "FSB time" as a table).
- **Kopia maintenance**: jobs per repository ok/failed, average duration. **Restores and deletions**. **Resources**.

Annotations: alerts and restarts in `velero`, backup started (`changes(velero_backup_attempt_total)`), backup failed or
partially failed. EMPTY at validation (all clear after the first scheduled run): last successful age per schedule,
average duration, tarball size (set on backup completion, current Pod has not completed one), volume copy time.

### Velero / Official
Source: grafana.com 16829 revision 5, published by the Velero project (the other candidate, 11055, is a 2019
single-author dashboard with removed metrics such as `velero_backup_active_total`). Removed: Restic row (metrics gone
since Restic was removed), CSI row, Data Mover row and the volume-snapshot gauge (never used here), their variables.
Kept: Backup, Restore, File System Backup rows (success rates are lifetime ratios since the Pod started). EMPTY: *Hours
since last Backup* (no scheduled backup yet), *Backup time heatmap* (no backup in the last hour), *Backup Size*, *FSB time*.

---

## Changes made in the apps (reach the cluster after commit + push)

- `helm-charts/argo/argo-cd/values.yaml.gotmpl`: `configs.params.controller.metrics.application.conditions:
  ComparisonError,SyncError,InvalidSpecError` (→ `argocd_app_condition`) and repo-server env
  `ARGOCD_ENABLE_GRPC_TIME_HISTOGRAM=true` (→ `grpc_server_handling_seconds_*`). Both restart the pods through the
  chart's checksum annotations. Only fields were added (rule 3: no helm apply needed).
- `helm-charts/keda/keda/values.yaml.gotmpl`: PrometheusRule via `prometheus.operator.prometheusRules` with
  `KedaScalerErrors` and `KedaScaledObjectErrors` (current metric names; the chart's commented example uses the removed
  `keda_metrics_adapter_scaler_errors`).
- `helm-charts/velero/velero/values.yaml.gotmpl`: alerts `VeleroBackupPartiallyFailed` (partial failures are not counted
  by `velero_backup_failure_total`, so `VeleroBackupFailed` missed them) and `VeleroBackupLocationUnavailable`.

Metrics to check after the sync: `argocd_app_condition`, `grpc_server_handling_seconds_bucket{job="argo-cd-repo-server-metrics"}`;
after the first scheduled Velero run: `velero_backup_last_successful_timestamp{schedule="velero-daily"}`,
`velero_backup_tarball_size_bytes`, `podVolume_pod_volume_operation_latency_seconds_gauge`.

## Gaps and recommendations

- **Velero volume size**: no metric reports how much data Kopia uploaded; `kubectl -n velero get podvolumebackups`
  shows bytes per volume. A restore test (runbook) is the only proof the backup is usable — no metric replaces it.
- **Velero repository maintenance failures**: no alert yet; the failure counter only appears on the first failure, so an
  `increase()` alert would miss it. Worth an alert like `velero_repo_maintenance_failure_total > 0` once the owner
  accepts that it stays firing until the Velero Pod restarts.
- **Argo CD**: consider an alert on `increase(grpc_server_handled_total{job="argo-cd-repo-server-metrics",grpc_method="GenerateManifest",grpc_code!="OK"}[15m]) > 0`
  if render errors should page before `ArgoAppNotSynced` (15 min). `argocd_app_orphaned_resources_count` stays 0 because
  the AppProject does not enable `orphanedResources`.
- **KEDA**: no extra component alerts needed: kube-prometheus-stack's `TargetDown` covers a dead component and
  `KubeAggregatedAPIDown`/`KubeAggregatedAPIErrors` cover the external metrics APIService.
