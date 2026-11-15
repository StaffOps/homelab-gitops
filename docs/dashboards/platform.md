# Dashboards: GitOps & Platform

Grafana folder **GitOps & Platform** (`helm-charts/monitoring/monitoring-raw/dashboards/platform/`). Services: Argo CD,
KEDA, Velero, Argo Rollouts, Argo Workflows, Argo Events. Every dashboard has a reading guide at the top, a description on each panel (with the source of the
query) and annotations for firing alerts and container restarts of the service namespace.

| Dashboard (uid) | Kind | File |
|-----------------|------|------|
| Argo CD / Operations (`hl-platform-argocd-ops`) | curated | `argocd-ops.json` |
| Argo CD / Official (`hl-platform-argocd`) | official, adapted | `argocd.json` |
| KEDA / Operations (`hl-platform-keda-ops`) | curated | `keda-ops.json` |
| KEDA / Official (`hl-platform-keda`) | official, adapted | `keda.json` |
| Velero / Backups (`hl-platform-velero-ops`) | curated | `velero-ops.json` |
| Velero / Official (`hl-platform-velero`) | community (Velero project), trimmed | `velero.json` |
| Argo Rollouts / Operations (`hl-platform-argo-rollouts-ops`) | curated | `argo-rollouts-ops.json` |
| Argo Rollouts / Official (`hl-platform-argo-rollouts`) | official (Argo Rollouts project), adapted | `argo-rollouts.json` |
| Argo Workflows / Operations (`hl-platform-argo-workflows-ops`) | curated | `argo-workflows-ops.json` |
| Argo Workflows / Overview (mixin) (`hl-platform-argo-workflows`) | community (argo-workflows-mixin), adapted | `argo-workflows.json` |
| Argo Events / Operations (`hl-platform-argo-events-ops`) | curated | `argo-events-ops.json` |

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

## Argo Rollouts

**What it does here.** Argo Rollouts v1.10.2 (chart 2.43.12, namespace `argo-rollouts`, one controller replica):
canary / blue-green `Rollout`s with Gateway API traffic splitting (plugin) and three Prometheus
**ClusterAnalysisTemplates** (`success-rate`, `p95-latency`, `pod-restarts`, argo-rollouts-raw). Seen and promoted from
the Argo CD rollout extension. **No Rollout exists yet.**

**Scrape job**: `argo-rollouts-metrics` (chart ServiceMonitor, :8090). Nothing else to scrape (dashboard disabled).
Reference: <https://github.com/argoproj/argo-rollouts/blob/v1.10.2/docs/features/controller-metrics.md>, definitions in
<https://github.com/argoproj/argo-rollouts/blob/v1.10.2/controller/metrics/prommetrics.go>. The scrape sets
`namespace=argo-rollouts`; the object's own namespace is `exported_namespace`.

| Family | Metrics | Meaning / use |
|--------|---------|---------------|
| Rollouts (appear with Rollouts) | `rollout_info{strategy,traffic_router,phase}`, `rollout_info_replicas_{desired,available,unavailable,updated}`, `rollout_events_total{type,reason}`, `rollout_phase` (deprecated) | phase = Completed / Progressing / Paused / Error / Abort / Timeout / InvalidSpec (computed in `controller/metrics/rollouts.go`) |
| Analysis | `analysis_template_info`, `analysis_template_metric_info{metric,type}` (live: 3 templates), `analysis_run_info{phase}`, `analysis_run_metric_phase{metric,type,dry_run,phase}`, `analysis_run_metric_type` | canary checks and their verdicts |
| Experiments | `experiment_info`, `experiment_phase`, `experiment_reconcile*` | not used here |
| Reconcile | `rollout_reconcile` / `analysis_run_reconcile` / `experiment_reconcile` (histograms, buckets ≤ 1 s), `*_reconcile_error` | controller latency and errors |
| Controller | `argo_rollouts_controller_info{version}`, `controller_clientset_k8s_request_total{kind,verb,status_code}`, `workqueue_*{name}`, `notification_send*` | health, API traffic, queues (Rollouts, AnalysisRuns, Experiments, Services, Ingresses, DestinationRules) |
| Runtime | `go_*`, `process_*` | Go client defaults |

### Argo Rollouts / Operations (curated)
Sources: D = docs controller-metrics.md, S = prommetrics.go/rollouts.go, U = upstream dashboard, W = client-go workqueue,
K = kubernetes-mixin.
- **Is Argo Rollouts up?** controller up, version (S), Rollouts (U), failed rollouts = Error/Abort/Timeout/InvalidSpec
  (U, alert `ArgoRolloutFailed`), paused, progressing (U), analysis templates (S), reconcile errors 24 h (D).
- **Rollouts**: table by phase/strategy/router (D), replicas desired/available/unavailable (D), events by reason (S).
- **Analysis**: templates and their metrics (S), AnalysisRuns by phase (D), metric results (D).
- **Controller**: reconcile p95 for the three kinds (D, U heatmap), reconcile errors (D), workqueue depth / wait p95 /
  work p95 (D, W), API requests by verb and code (D), notifications (S), Go heap + goroutines (U "Memory Used").
- **Resources**: memory vs limit, CPU (K).

EMPTY at validation (all expected while no Rollout exists): Rollouts table, replicas, events, AnalysisRuns, metric
results, the three reconcile latencies and errors, notifications (no notification service configured).

### Argo Rollouts / Official
Source: <https://github.com/argoproj/argo-rollouts/blob/v1.10.2/examples/dashboard.json> (tag = installed version;
linked from the controller-metrics docs). Changes: the Rollout namespace variable and filters use `exported_namespace`
(upstream `namespace` would only offer `argo-rollouts`), datasource fixed, refresh 5 s → 1 m, homelab annotations,
reading guide, descriptions. Legacy `singlestat`/`graph` panels are auto-migrated by Grafana. EMPTY: every panel except
*Uptime* and *Memory Used* (no Rollout); variables have no values for the same reason.

---

## Argo Workflows

**What it does here.** Argo Workflows v4.1.6 (chart 2.0.18, namespace `argo-workflows`): workflow-controller and
argo-server (UI/API with Keycloak SSO), archive of finished workflows in CloudNativePG `workflows-db` (30 days), logs and
artifacts in R2, ClusterWorkflowTemplates `argocd-sync` and `github-watch`.

**Scrape jobs**: `argo-workflows-workflow-controller` (chart ServiceMonitor, :9090 `/metrics`), `argo-workflows/workflows-db`
(CNPG PodMonitor, see Databases). **argo-server is not scraped**: its `/metrics` on :2746 answers **403** without a
bearer token (checked with a port-forward); the dashboard uses kube-state-metrics for it. Reference:
<https://github.com/argoproj/argo-workflows/blob/v4.1.6/docs/metrics.md>. Metrics are OpenTelemetry instruments exported
with the `argo_workflows_` prefix; several counters have no `_total` suffix (`argo_workflows_total_count`,
`argo_workflows_error_count`, `argo_workflows_queue_adds_count`, `argo_workflows_log_messages`, `argo_workflows_pod_missing`).

| Family | Metrics | Meaning / use |
|--------|---------|---------------|
| Workflows | `argo_workflows_gauge{phase}`, `argo_workflows_total_count{phase,exported_namespace}`, `argo_workflows_workflow_condition{type,status}` | workflows in the cluster per phase; phase transitions (appear after the first workflow handled by the current Pod) |
| Templates / cron | `argo_workflows_workflowtemplate_triggered_total{name,cluster_scope,phase}`, `argo_workflows_workflowtemplate_runtime` (histogram), `argo_workflows_cronworkflows_triggered_total`, `argo_workflows_cronworkflows_concurrencypolicy_triggered` | template usage and run time; CronWorkflow runs |
| Pods | `argo_workflows_pods_gauge{phase}`, `argo_workflows_pods_total_count`, `argo_workflows_pod_pending_count{reason}`, `argo_workflows_pod_missing`, `argo_workflows_pod_restarts_total{reason}` | workflow pods; pending reasons, infrastructure restarts |
| Controller | `argo_workflows_error_count{cause}`, `argo_workflows_log_messages{level}`, `argo_workflows_operation_duration_seconds`, `argo_workflows_is_leader`, `argo_workflows_version`, `argo_workflows_workers_busy_count{worker_type}` | errors (OperationPanic, CronWorkflowSubmissionError, CronWorkflowSpecError), reconcile time, saturation |
| Queues | `argo_workflows_queue_{adds_count,depth_gauge,latency,duration,retries,longest_running,unfinished_work}{queue_name}` | workflow, cron_wf, pod_cleanup, workflow_ttl, workflow_archive queues |
| K8s API | `argo_workflows_k8s_request_total` / `_duration{kind,verb,status_code}`, `argo_workflows_client_rate_limiter_latency`, `argo_workflows_resource_rate_limiter_latency` | API traffic, client-go throttling |
| Not in the docs list | `argo_workflows_db_client_operation_duration{db_operation_name}` (archive DB, OTel database semconv), `argo_workflows_http_client_request_*` (HTTP clients, today the API server), `argo_workflows_go_*` (OTel Go runtime) | archive DB latency |
| Not present yet | `locks_*`, `deprecated_feature`, custom metrics | appear when used |

### Argo Workflows / Operations (curated)
Sources: D = docs metrics.md v4.1.6, M = argo-workflows-mixin c331414, G = grafana.com 21393 (linked from the docs; built
for v3.6, several names differ in v4, so not imported), K = kubernetes-mixin / kube-state-metrics.
- **Is Argo Workflows up?** controller up, leader, version (D), server pods ready (K), archive DB exporter up (CNPG),
  running / pending / failed+error workflows in the cluster (D, M).
- **Workflows**: by phase (D, M), phase changes (D, M), success rate 24 h and completions 24 h (M), template runs by phase
  (D), template runtime p95 (D, G), CronWorkflow triggers and concurrency-policy suppressions (D, M).
- **Workflow pods**: by phase, pending by reason, missing/restarted (D, M).
- **Controller**: errors by cause, log messages by level, operation duration p50/p95, queue depth, queue latency p95,
  busy workers, API requests by code, API p95, client rate-limiter p95 (D, M).
- **Archive database**: SQL operations/s and average latency (OTel semconv).
- **Resources**: whole namespace (controller, server, workflow pods, workflows-db).

Annotations: alerts and restarts in `argo-workflows`, workflow ended Failed/Error. EMPTY at validation: phase changes,
template runs/runtime, CronWorkflow triggers, pods pending, missing/restarted pods (counters appear on the first event
handled by the current controller Pod, and no workflow has run since it started),
operation duration, queue depth/latency (no workflow reconciled in the window).

### Argo Workflows / Overview (mixin)
Source: <https://github.com/adinhodovic/argo-workflows-mixin/blob/c331414c1bb3bf95f4f83c951cea298674290152/dashboards_out/argo-workflows-overview.json>
(same mixin as the alerts; targets v3.6+/v4 names). Changes: `cluster` variable and filters removed (one cluster, no
`cluster` label), variables read from `argo_workflows_gauge` with All = `.*` (upstream read `argo_workflows_total_count`,
empty until a workflow runs, which blanked every panel), datasource fixed, annotations, reading guide. The mixin's
*Controller* dashboard is not imported: the curated Controller row covers it. EMPTY: everything built on
`argo_workflows_total_count`, `pod_pending_count`, `pod_restarts_total`, `pod_missing`, the CronWorkflow counters, and the
operation-duration histogram (same reason as above).

---

## Argo Events

**What it does here.** Argo Events v1.9.11 (chart 2.4.28, namespace `argo-events`): controller-manager; EventBus
`default` (NATS JetStream 2.10.29, one server, 5 Gi local-path volume, stream limits 100000 msgs / 72 h / 1 GB);
EventSource `argocd` (webhook for Argo CD notifications) and Sensor `argocd` (trigger `log`).

**Scrape jobs**: `argo-events-controller-manager-metrics` (chart ServiceMonitor, :7777, controller-runtime metrics only).
**Added by this change (pending scrape)** — PodMonitors in `argo-events-raw/resources/monitoring.yaml`, port `metrics`
(7777): `argo-events/eventsources` (`controller=eventsource-controller`), `argo-events/sensors`
(`controller=sensor-controller`), `argo-events/eventbus` (`controller=eventbus-controller`: the
prometheus-nats-exporter 0.14.0 sidecar). Endpoints and metric names were checked on the pods with a port-forward. The
docs' scrape example is <https://github.com/argoproj/argo-events/blob/v1.9.11/docs/metrics.md>.

| Family | Metrics | Meaning / use |
|--------|---------|---------------|
| EventSource (pending scrape) | `argo_events_event_service_running_total`, `argo_events_events_sent_total`, `argo_events_events_sent_failed_total`, `argo_events_events_processing_failed_total` (includes sent_failed), `argo_events_event_processing_duration_milliseconds` (summary, _sum/_count only) | labels `eventsource_name`, `event_name`; the docs' golden signals |
| Sensor (pending scrape) | `argo_events_action_triggered_total`, `argo_events_action_failed_total`, `argo_events_action_retries_failed_total`, `argo_events_action_duration_milliseconds` (summary) | labels `sensor_name`, `trigger_name` |
| EventBus (pending scrape) | `nats_varz_*` (server: msgs, bytes, mem, cpu, connections, slow consumers, JetStream stats/config), `nats_server_*`, `nats_stream_*{stream_name}`, `nats_consumer_*{consumer_name}`, `nats_connz_*`, `nats_routez_*`, `nats_subsz_*` | exporter prefix is `nats_` (upstream default `gnatsd_`); stream `default` = events, `KV_<sensor>` = Sensor state |
| Controller | `controller_runtime_*{controller}`, `workqueue_*`, `rest_client_requests_total`, `certwatcher_*` | reconcile of eventbus/eventsource/sensor controllers |

### Argo Events / Operations (curated)
Sources: E = Argo Events metrics docs v1.9.11, N = NATS monitoring docs / prometheus-nats-exporter v0.14.0, KB =
controller-runtime metrics reference, K = kube-state-metrics / kubernetes-mixin. No upstream Argo Events dashboard exists.
- **Is Argo Events up?** controller up, EventSource / Sensor Deployments available, EventBus StatefulSet ready, version
  (K), event services running and failed events 24 h (E).
- **EventSources**: events sent, failed events, average processing time (E).
- **Sensors**: actions triggered, failed actions / retries exhausted, average action duration (E).
- **EventBus**: exporter up, NATS version, connections, slow consumers, JetStream storage, memory, JetStream API errors,
  CPU, messages in/out, stream size, consumer backlog (N).
- **Controller**: reconciles by result, errors, workqueue depth, reconcile p95, API responses (KB). **Resources** (K).

EMPTY at validation: every EventSource, Sensor and EventBus panel (pending scrape, 23 queries). The PVC usage of the
EventBus is not shown: `kubelet_volume_stats_*` reports the node filesystem for local-path volumes.

---

## Changes made in the apps (reach the cluster after commit + push)

- `helm-charts/argo/argo-cd/values.yaml.gotmpl`: `configs.params.controller.metrics.application.conditions:
  ComparisonError,SyncError,InvalidSpecError` (→ `argocd_app_condition`) and repo-server env
  `ARGOCD_ENABLE_GRPC_TIME_HISTOGRAM=true` (→ `grpc_server_handling_seconds_*`). Both restart the pods through the
  chart's checksum annotations. Only fields were added (rule 3: no helm apply needed).
- `helm-charts/keda/keda/values.yaml.gotmpl`: PrometheusRule via `prometheus.operator.prometheusRules` with
  `KedaScalerErrors` and `KedaScaledObjectErrors` (current metric names; the chart's commented example uses the removed
  `keda_metrics_adapter_scaler_errors`).
- `helm-charts/argo-rollouts/argo-rollouts-raw/prometheus.rules.yaml` (PrometheusRule `argo-rollouts`): `ArgoRolloutFailed`
  (phase Error/Abort/Timeout/InvalidSpec for 5 m; phases from `controller/metrics/rollouts.go` v1.10.2 and the project
  dashboard) and `ArgoRolloutsReconcileErrors` (`increase(rollout_reconcile_error[15m]) > 0`; docs controller-metrics.md).
  Argo Rollouts ships no alert rules.
- `helm-charts/argo-workflows/argo-workflows-raw/prometheus.rules.yaml` (PrometheusRule `argo-workflows`): the four alerts
  of argo-workflows-mixin c331414 (`ArgoWorkflowsHighWorkflowFailureRate`, `ArgoWorkflowsPendingWorkflows`,
  `ArgoWorkflowsControllerHighErrorRate`, `ArgoWorkflowsQueueDepthHigh`), thresholds as upstream, grouped by `namespace`
  instead of `cluster`.
- `helm-charts/argo-events/argo-events-raw/resources/monitoring.yaml`: PodMonitors `eventsources`, `sensors`, `eventbus`.
  `helm-charts/argo-events/argo-events-raw/prometheus.rules.yaml` (PrometheusRule `argo-events`):
  `ArgoEventsEventProcessingFailed` and `ArgoEventsSensorActionFailed` (derived from the "Errors" golden signals of the
  Argo Events metrics docs; the project ships no rules) and five NATS rules from awesome-prometheus-alerts a533dc4
  (`NatsServerDown`, `NatsHighCpuUsage`, `NatsHighMemoryUsage`, `NatsSlowConsumers`, `NatsTooManyErrors`; `gnatsd_` →
  `nats_`, job selector added, thresholds as upstream).
- `helm-charts/velero/velero/values.yaml.gotmpl`: alerts `VeleroBackupPartiallyFailed` (partial failures are not counted
  by `velero_backup_failure_total`, so `VeleroBackupFailed` missed them) and `VeleroBackupLocationUnavailable`.

Metrics to check after the sync of argo-events: `up{job=~"argo-events/(eventsources|sensors|eventbus)"}`,
`argo_events_events_sent_total`, `argo_events_action_triggered_total`, `nats_varz_connections` (then `NatsServerDown`
must resolve: it fires while the eventbus job does not exist).

Metrics to check after the sync: `argocd_app_condition`, `grpc_server_handling_seconds_bucket{job="argo-cd-repo-server-metrics"}`;
after the first scheduled Velero run: `velero_backup_last_successful_timestamp{schedule="velero-daily"}`,
`velero_backup_tarball_size_bytes`, `podVolume_pod_volume_operation_latency_seconds_gauge`.

## Gaps and recommendations

- **Velero volume size**: no metric reports how much data Kopia uploaded; `kubectl -n velero get podvolumebackups`
  shows bytes per volume. A restore test (runbook) is the only proof the backup is usable — no metric replaces it.
- **Alert added — `VeleroRepoMaintenanceFailed`** (velero chart `metrics.prometheusRule`):
  `velero_repo_maintenance_failure_total > 0`, warning. The counter only appears on the first failure (so `increase()`
  would miss it); the alert stays firing until the Velero Pod restarts.
- **Alert added — `ArgoRepoServerRenderErrors`** (argo-cd chart `controller.metrics.rules`):
  `increase(grpc_server_handled_total{job="argo-cd-repo-server-metrics",grpc_method="GenerateManifest",grpc_code!="OK"}[15m]) > 0`,
  warning — fires before `ArgoAppNotSynced` (15 min). `argocd_app_orphaned_resources_count` stays 0 because the
  AppProject does not enable `orphanedResources`.
- **KEDA**: no extra component alerts needed: kube-prometheus-stack's `TargetDown` covers a dead component and
  `KubeAggregatedAPIDown`/`KubeAggregatedAPIErrors` cover the external metrics APIService.
- **Argo Workflows server metrics**: `/metrics` on :2746 answers 403 without a token, so the server is not scraped (the
  dashboard uses kube-state-metrics). Scraping it needs a ServiceMonitor with a bearer token of a ServiceAccount the server
  accepts (`--auth-mode=client`); not done — the controller carries the workflow signals.
- **Argo Workflows controller errors**: the mixin's `ArgoWorkflowsControllerHighErrorRate` fires above 5 errors/s; a single
  `CronWorkflowSubmissionError` (a scheduled run that was not created, e.g. `github-watch`) stays below it. The curated
  dashboard shows every error by cause; a lab threshold (`increase(...[15m]) > 0`) would be a local addition, not upstream.
- **NATS**: `NatsSlowConsumers` uses a cumulative counter (fires until the EventBus pod restarts); JetStream store usage is
  not alerted because its max comes from the node disk — `KubePersistentVolumeFillingUp` would cover the PVC, but
  local-path reports the node filesystem. `nats_varz_jetstream_stats_api_errors` was already 3 at validation (cumulative).
- **Argo Rollouts**: rules and most panels are dormant until the first Rollout; `ArgoRolloutsReconcileErrors` misses the
  first error of a Rollout (counter created on it).
