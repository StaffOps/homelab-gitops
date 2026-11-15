# Dashboards: Observability

Grafana folder **Observability**, files in `helm-charts/monitoring/monitoring-raw/dashboards/observability/` (one
ConfigMap `dashboard-observability-<name>` each, rendered by `monitoring-raw`).

| Dashboard | uid | File | Kind |
|-----------|-----|------|------|
| Prometheus | `hl-observability-prometheus` | `observability/prometheus.json` | curated (prometheus-mixin) |
| Prometheus Operator | `hl-observability-prometheus-operator` | `observability/prometheus-operator.json` | curated (operator mixin alerts; no upstream dashboard) |
| Alertmanager | `hl-observability-alertmanager` | `observability/alertmanager.json` | curated (alertmanager-mixin) |
| Grafana | `hl-observability-grafana` | `observability/grafana.json` | curated (grafana-mixin) |
| Loki | `hl-observability-loki` | `observability/loki.json` | curated (loki-mixin, monolithic only) |
| Tempo | `hl-observability-tempo` | `observability/tempo.json` | curated (tempo-mixin, v3 single binary only) |
| OpenTelemetry Collectors | `hl-observability-otel-collectors` | `observability/otel-collectors.json` | curated (collector internal telemetry, grafana.com 15983 as reference) |
| OpenTelemetry Operator & OBI | `hl-observability-otel-operator` | `observability/otel-operator.json` | curated (controller-runtime; no upstream dashboard) |

No official dashboard was imported into this folder:

- kube-prometheus-stack already ships the upstream mixin dashboards *Prometheus / Overview*, *Alertmanager /
  Overview* and *Grafana Overview* (folder **Kubernetes**). They are the reference; the curated ones here add the
  TSDB/WAL, cardinality, OTLP, rule and delivery panels those overviews lack.
- Loki's and Tempo's mixin dashboards target the distributed deployments (component containers, memcached,
  object stores, Kafka consumers, ingesters/compactors): most panels would be empty here. Loki's chart dashboards
  are disabled on purpose (`monitoring.dashboards.enabled: false` in `helm-charts/monitoring/loki`).
- The OpenTelemetry project publishes no dashboard. grafana.com 15983 ("OpenTelemetry Collector", Monitoring
  Artist, revision 31) is a community dashboard; it was used as the formula reference (it even carries a
  `suffix_total` variable because the `_total` suffix changes between collector versions) but not imported:
  it is a single-collector, 100+ panel board.

Every dashboard has a dashboard description, a "How to read this dashboard" text panel, a description on every
panel (what it shows, normal vs bad, metric and formula source), thresholds from the mixin alerts, a dropdown to
the other Observability dashboards, and annotations: firing alerts of the service (`ALERTS{alertstate="firing"}`
by alert name / namespace / pod), container restarts
(`changes(kube_pod_container_status_restarts_total{…}[2m]) > 0`), plus service events listed per section.

Validated with `scripts/check-dashboard.py` against the live Prometheus (Prometheus v3.16.0): **0 errors** on all
eight files; annotation queries were run separately as 24 h range queries (all valid). Every EMPTY result is
listed under its service. The JSON is generated (helper kept outside the repository); edit the files directly or
regenerate, both are fine.

**State of the pipeline when this was written (important to read the EMPTY lists):** no workload sends OTLP traces
or metrics yet. OBI instruments only namespaces matching `staffops*` (none exist), no app has an SDK, and the VPS
is not sending. Only `otel-logs` moves data (pod logs + Kubernetes events -> Loki). Every span / metric-point
panel of the collectors, Tempo's ingestion panels and Prometheus' OTLP panels are therefore empty, and fill in as
soon as something sends telemetry.

---

## Prometheus (`prometheus-kps-0`)

**What it does here.** Single Prometheus v3.16.0 (kube-prometheus-stack 93.3.0) selecting every ServiceMonitor,
PodMonitor and PrometheusRule in the cluster; OTLP receiver on `/api/v1/otlp` (fed by the otel-gateway,
`translationStrategy: UnderscoreEscapingWithSuffixes`); retention 15 d / 18 GiB on local-path (20 Gi PVC);
default scrape interval 30 s (some ServiceMonitors use 10 s / 15 s / 1 m). ~283k head series, ~5.8k samples/s.

**Scrape.** Job `kps-prometheus` (ServiceMonitor from the chart): container `prometheus` (port http-web) and the
`config-reloader` sidecar (port reloader-web). ~400 metric names.

| Family | Meaning / use |
|--------|---------------|
| `prometheus_tsdb_head_*` | head block: `head_series` (cardinality), `head_samples_appended_total{type}` (ingestion), `head_series_created/removed_total` (churn), `head_chunks`, `head_truncations_failed_total` |
| `prometheus_tsdb_wal_*`, `prometheus_tsdb_checkpoint_*` | WAL size, fsync latency (summary), corruptions, failed writes/truncations/checkpoints |
| `prometheus_tsdb_compactions_*`, `prometheus_tsdb_reloads_*`, `prometheus_tsdb_storage_blocks_bytes`, `prometheus_tsdb_retention_limit_*`, `prometheus_tsdb_{time,size}_retentions_total`, `prometheus_tsdb_lowest_timestamp_seconds` | persisted blocks, retention and their failures |
| `prometheus_tsdb_out_of_order/too_old/out_of_bound_samples_total` | samples rejected by the TSDB (OTLP pushes with old timestamps) |
| `prometheus_target_*` | scraping: interval length, sync length/failures, scrape-pool reloads, limit hits, duplicate/out-of-order timestamps |
| `prometheus_sd_*` | service discovery: discovered targets, Kubernetes list/watch failures (other SD mechanisms export zeros) |
| `prometheus_rule_*` | rule groups: evaluations, failures, missed iterations, last duration vs interval, loaded rules |
| `prometheus_notifications_*` | alerts sent to Alertmanager: sent/errors/dropped, queue length/capacity, latency (summary), Alertmanagers discovered |
| `prometheus_engine_*` | query concurrency and per-stage latency (summary) |
| `prometheus_http_requests_total`, `prometheus_http_request_duration_seconds` | API by handler/code; the OTLP handler is `/api/v1/otlp/v1/metrics` |
| `prometheus_api_otlp_*` | OTLP samples without metadata, out-of-order exemplars |
| `prometheus_remote_storage_*_in_total` | remote-write receiver counters (no remote write configured) |
| `scrape_*`, `up` | auto-generated per target (used cluster-wide for target health and per-job cardinality/churn) |
| `reloader_*` | config-reloader sidecar: last reload successful, failures |
| `go_*`, `process_*`, `net_conntrack_*` | runtime |

**Dashboard rows** (formula sources: [prometheus-mixin](https://github.com/prometheus/prometheus/tree/main/documentation/prometheus-mixin)
dashboards and alerts, [Prometheus storage docs](https://prometheus.io/docs/prometheus/latest/storage/),
[auto-generated series](https://prometheus.io/docs/concepts/jobs_instances/), kubernetes-mixin for pod resources):

- Overview: up, uptime, config reload (PrometheusBadConfig), head series, samples/s, targets down (TargetDown),
  rule failures 1h, alert send errors 1h, disk used / size-retention limit.
- Ingestion and cardinality: samples appended by type, head series + created/removed, OOO/too-old samples, top 10
  jobs by samples per scrape (`scrape_samples_post_metric_relabeling`), top 10 jobs by series churn
  (`sum_over_time(scrape_series_added[1h])`).
- Scraping: table per job (up / total / samples / slowest scrape), targets down by job, slowest scrapes, scrape
  errors by cause (mixin), SD targets and failures, target sync, average scrape interval (mixin).
- Rule evaluation: failures and missed iterations by group, duration/interval ratio, evaluation latency, rules
  loaded and evaluations/s.
- TSDB and WAL: storage size vs retention limit, compactions/reload failures, WAL failures, fsync latency, head
  chunks / blocks loaded, retention (oldest data, time vs size retentions).
- OTLP ingestion: OTLP and remote-write requests by code, OTLP latency, OTLP data quality.
- Alert delivery: sent/errors/dropped, queue vs capacity + Alertmanagers discovered, latency.
- Queries: concurrency vs max (PrometheusHighQueryLoad), latency by stage p90 (mixin), API 5xx.
- Resources: CPU, memory vs 4 GiB limit + Go heap, config-reloader sidecar.

**Annotations:** firing `Prometheus*|TargetDown|ConfigReloaderSidecarErrors` alerts, restarts, config reloads
(`changes(prometheus_config_last_reload_success_timestamp_seconds[2m])`), TSDB compactions (off by default).

**EMPTY (expected):** *Targets down by job* (no target down), *Rule evaluation failures* and *Missed iterations*
(none in the window), *OTLP request latency* (histogram created on the first OTLP request; nothing is pushed
yet), *HTTP API errors* (no 5xx).

## Prometheus Operator

**What it does here.** `prometheus-operator` Deployment (kube-prometheus-stack) renders ServiceMonitors (49),
PodMonitors (10) and PrometheusRules (45) from every namespace into the Prometheus/Alertmanager config.

**Scrape.** Job `prometheus-operator`, ~160 names: `prometheus_operator_*` (managed resources by kind/state
`selected|rejected`, reconcile/list/watch/status-update operations and failures, syncs by status, node address
lookups for the kubelet Service, work queues, Kubernetes client requests, readiness, feature gates) + runtime.

**Dashboard:** up, ready, rejected resources, failed syncs, selected monitors and rules, config reloaders;
managed resources by kind/state, reconcile error ratio, reconcile rate/duration, list/watch error ratios,
status-update and node-lookup errors, work queues, resources, API calls by code. Thresholds = the
[prometheus-operator mixin](https://github.com/prometheus-operator/prometheus-operator/tree/main/jsonnet/mixin)
alerts (reconcile/status errors > 10 %, list/watch > 40 %, node lookups > 0.1/s, rejected > 0, not ready).

**Annotations:** firing `PrometheusOperator*|ConfigReloaderSidecarErrors`, restarts, reconciles with errors.

**EMPTY:** none.

**Finding (needs the Kubernetes owner of kps values):** the chart's `prometheus-operator` PrometheusRule selects
`job="kps-operator"`, but the scrape job is `prometheus-operator` (`prometheus_operator_ready{job="prometheus-operator"}`).
None of the eight `PrometheusOperator*` alerts can fire. Fix in kube-prometheus-stack values (e.g. align the
operator Service/ServiceMonitor job label with the rule selector, or override the rule selector).

## Alertmanager (`alertmanager-kps-0`)

**What it does here.** Single Alertmanager (no cluster), 1 Gi PVC for silences / notification log.
**It has no real receiver:** `alertmanager_receivers` = 1 (the chart's default `null` receiver), every
`alertmanager_notifications_total{integration}` is 0. Alerts are evaluated and visible in the UI but nobody is
notified. Configure `alertmanager.config` (receivers + route) in kube-prometheus-stack values.

**Scrape.** Job `kps-alertmanager` (alertmanager + config-reloader containers), ~200 names:
`alertmanager_alerts{state}`, `alerts_received/invalid_total`, `notifications_total` / `notifications_failed_total{integration,reason}` /
`notification_latency_seconds` (histogram) / `notification_requests_*`, `notifications_suppressed_total{reason}`,
`silences{state}` and silence/nflog maintenance and query errors, `dispatcher_aggregation_groups`, `config_*`,
`receivers`, `integrations`, `http_*`, `cluster_enabled` (0) + runtime.

**Dashboard:** up, config, receivers, active / suppressed alerts, active silences, notification failures 1h,
uptime, silence/nflog errors; firing-alerts table (from Prometheus `ALERTS`), alerts by state, received/invalid;
notifications by integration, failure ratio (AlertmanagerFailedToSendAlerts > 1 %), latency p99/p50, aggregation
groups, low-level request failures, silences by state; resources and config-reloader. Source:
[alertmanager-mixin](https://github.com/prometheus/alertmanager/tree/main/doc/alertmanager-mixin).

**Annotations:** firing `Alertmanager*|PrometheusErrorSendingAlerts*|PrometheusNotConnectedToAlertmanagers`,
restarts, config reloads.

**EMPTY (expected):** *Notifications sent by integration* (nothing sent: no receiver; the suppressed counter is
created on the first suppression after a restart), *Notification requests failed* (same reason).

## Grafana

**What it does here.** Grafana 13.3.1 (`grafana` Deployment), dashboards and datasources from ConfigMaps
(k8s-sidecar), OIDC login via Keycloak, SQLite database.

**Scrape.** Job `grafana` (ServiceMonitor from the chart), ~800 names. Used: `grafana_http_request_duration_seconds`
(histogram by handler/status_code/method), `grafana_plugin_request_total` / `_duration_seconds` (backend datasource
queries by plugin_id/status), `grafana_authn_*` (logins), `grafana_alerting_alerts{state}` /
`schedule_alert_rules` / `scheduler_behind_seconds`, `grafana_database_conn_*`, `grafana_stat_*` (users,
dashboards...), `grafana_build_info`, `grafana_process_*`. Not used: `grafana_apiserver_*`, `grafana_index_server_*`,
`grafana_live_*`, `grafana_provisioning_*` (git sync), `openfga_*`, `grafana_unified_storage_*` — internals of the
new storage/search layers, no operational question for a single small instance.

**Dashboard:** up, version, uptime, 5xx ratio (GrafanaRequestsFailing expression, excluding datasource proxy
handlers), datasource query errors 1h, active users, dashboards, failed logins; RPS by status, latency
p99/p50/avg (mixin), 5xx by handler; datasource requests by plugin/status and p99; Grafana-managed alerts, scheduler
lag, logins, DB connections, dashboard provisioning reloads; resources. Source:
[grafana-mixin](https://github.com/grafana/grafana/tree/main/grafana-mixin) (its *Firing Alerts* panel uses
`grafana_alerting_result_total`, which Grafana 13 no longer exports; replaced by `grafana_alerting_alerts{state}`).

**Annotations:** firing alerts for the Grafana pod/job or `GrafanaRequestsFailing`, restarts, dashboard
provisioning reloads (off by default; every dashboard ConfigMap change triggers one).

**EMPTY (expected):** *5xx by handler* (no 5xx in the window), *Grafana-managed alerts by state* (no Grafana-managed
rules; the lab alerts with Prometheus rules), *Dashboard provisioning reloads* (no ConfigMap changed in the window).

## Loki (`loki-0`, monolithic)

**What it does here.** Loki 3.7 single binary (chart grafana-community/loki 21.2.3), filesystem storage + TSDB
index on local-path (20 Gi), 7-day retention by the compactor, auth disabled (tenant `fake`), pattern ingester on.
Writers: `otel-logs` (direct, OTLP/HTTP) and `otel-gateway` (OTLP logs from apps).

**Scrape.** Job `monitoring/loki` (chart ServiceMonitor), ~580 names: `loki_distributor_*` (bytes/lines/structured
metadata received), `loki_discarded_samples/bytes_total{reason}`, `loki_request_duration_seconds{route,status_code}`
(every HTTP/gRPC route), `loki_ingester_*` (streams, chunks, flushes, WAL, checkpoints), `loki_chunk_store_*`,
`loki_index_request_duration_seconds`, `loki_query_frontend/scheduler/querier_*`, `loki_compactor_*` (retention, delete
requests), `loki_tsdb_*` (index build/shipper), `loki_boltdb_shipper_*` (still exported by the compactor),
`loki_panic_total`, `loki_internal_log_messages_total{level}`, `loki_pattern_*`, `loki_memberlist_*` (ring of one),
`loki_rate_store_*` + runtime. The chart also ships PrometheusRules `loki_rules` (latency recording rules) and
`loki_alerts` (LokiRequestErrors > 10 % 5xx, LokiRequestPanics, LokiRequestLatency p99 > 1 s,
LokiCompactorHasNotSuccessfullyRunCompaction, LokiTooManyCompactorsRunning).

**Changes in this review** (the previous version was already validated): uid `loki-monolithic` →
`hl-observability-loki` (folder convention; old bookmarks break), dashboard description + text panel, description
on every panel with its loki-mixin source, alert/restart/retention annotations, new stats *Push 5xx* (LokiRequestErrors
ratio) and *Panics (1h)*, 1 s threshold lines on push/query latency (LokiRequestLatency), fixed *Pending delete
requests* (it queried `loki_compactor_pending_delete_requests`, which does not exist — the metric is
`..._count` — and only showed `vector(0)`). Kept monolithic-specific: no per-component/container, object-store,
cache or bloom panels.

**Dashboard rows:** overview (up, ingestion, lines/s, streams, discarded 1h, push 5xx, panics, node disk, restarts);
write path (bytes/lines by tenant, discarded by reason, push requests and latency, structured metadata); read path
(requests by route/status, latency, queries in progress, result cache, chunks per query, TSDB index latency);
ingester and storage (streams churn, flushes/failures/queue, chunk utilization/compression, bytes stored, WAL, WAL
disk/failures); compactor (last retention run, last TSDB index build, pending deletes, retention/index operations);
resources (CPU, memory, goroutines/log levels, node filesystem). Source:
[loki-mixin](https://github.com/grafana/loki/tree/main/production/loki-mixin) (loki-writes, loki-reads,
loki-chunks, loki-retention, loki-resources).

**Annotations:** firing `Loki*` or loki-0 alerts, restarts, retention runs (off by default, every 10 min).

**EMPTY (expected):** *Discarded samples by reason* (nothing discarded).

**Note:** the query routes show a few `500` on `loki_api_v1_query[_range]` in the last hours (large/aborted Explore
queries); watch the *Query requests* panel if they persist.

## Tempo (`tempo-0`, v3 single binary)

**What it does here.** Tempo 3.1.1 (chart grafana-community/tempo 3.2.1), local storage on local-path (20 Gi),
7-day retention, OTLP gRPC/HTTP receivers fed by the otel-gateway, metrics generator off, MCP server at `/api/mcp`.

**Scrape.** Job `tempo` (chart ServiceMonitor), ~170 names. Tempo v3 has **no** `tempo_ingester_*` or
`tempo_compactor_*` metrics; the single binary exports instead: `tempo_live_store_*` (ready, completion queue,
blocks completed, failed completions/flushes and retries, back-pressure, catch-up), `tempo_block_builder_*`,
`tempo_backend_scheduler_*` / `tempo_backend_worker_*` (compaction/retention jobs), `tempodb_*` (retention,
compaction errors, blocklist poll, work queue), `tempo_distributor_*` (traces per batch, ingest write latency),
`tempo_request_duration_seconds{route,status_code}`, `tempo_inflight_requests`, `tempo_tcp_connections`,
`tempo_ring_*` / `tempo_partition_ring_*` (rings of one), `tempo_runtime_config_*`, `tempo_limits_defaults`,
`tempo_build_info` + runtime. Lazily created (appear with the first trace): `tempo_receiver_accepted/refused_spans`,
`tempo_distributor_spans/bytes_received_total`, `tempo_discarded_spans_total`.

**Dashboard rows:** overview (up, version, live-store ready, spans accepted/s, refused + discarded 1h, overrides OK
(TempoBadOverrides), live-store unhealthy (TempoLiveStoreUnhealthy), node disk, restarts); write path (receiver
spans, distributor spans/bytes, discarded by reason, traces per batch / write latency, inflight/TCP); live-store and
block building (completion queue/blocks completed, failures, back-pressure/catch-up, rings, block builder); backend
(compaction/retention errors (TempoCompactionsFailing), retention marked/deleted, worker retries
(TempoBackendWorkerCallRetriesHigh > 5/min) and work queue %, blocklist poll duration, scheduler empty cycles);
read path (requests by route/status, p99 by route, querier/frontend); resources. Source:
[tempo-mixin](https://github.com/grafana/tempo/tree/main/operations/tempo-mixin) (tempo-writes, tempo-reads,
tempo-operational, tempo-resources, alerts). Distributed-only panels (memcached, gateway, Kafka lag, vulture,
metrics generator, memberlist) were left out.

**Expected noise:** the backend worker polls `/tempopb.BackendScheduler/Next` and gets `NotFound: no jobs found`
when there is nothing to compact (seen in the logs as level=error). It shows up as `status_code="error"` requests
and ~45 worker call retries per hour; filtered out of the request panels, harmless under the mixin's 5/min.

**Annotations:** firing `Tempo*` / tempo-0 / job tempo alerts, restarts, overrides reloads
(`changes(tempo_runtime_config_hash[2m])`).

**EMPTY (expected, no traces sent yet):** *Spans accepted / s*, *Receiver spans / s*, *Distributor received*,
*Discarded spans by reason* (lazy counters), *Requests by route / status* and *Request latency p99 by route*
(nobody queried Tempo in the window once the health/stream/poll routes are filtered).

## OpenTelemetry Collectors (otel-agent, otel-gateway, otel-logs)

**What they do here.** Collector contrib 0.165.0 run by the operator (CRs in `helm-charts/opentelemetry/opentelemetry-raw/resources/`):
`otel-agent` DaemonSet (OTLP from apps/OBI, k8s_attributes, filter/noise, forwards to the gateway),
`otel-gateway` Deployment (OTLP from agents + authenticated `otlp/external` for the VPS; span_metrics and
service_graph connectors; exports to Tempo, Prometheus OTLP and Loki), `otel-logs` DaemonSet (file_log on
/var/log/pods + k8s_objects events with leader election, straight to Loki).

**Scrape.** The operator creates a `*-collector-monitoring` Service + ServiceMonitor per collector
(`observability.metrics.enableMetrics: true`), jobs `otel-agent-collector-monitoring`,
`otel-gateway-collector-monitoring`, `otel-logs-collector-monitoring`, port 8888. `service.telemetry.metrics.level`
is already **normal** on all three (the level that adds `otelcol_exporter_queue_*`, `otelcol_processor_*` and the
batch histogram); `detailed` would only add per-request HTTP/gRPC server/client metrics, not needed. The ~25-70
series per collector are not a telemetry-level problem: most counters are created on first use, and only otel-logs
carries data today.

Metric names (verified on the endpoints): collector 0.165 exposes counters **without `_total`**
(`otelcol_receiver_accepted_log_records`, `otelcol_process_cpu_seconds`, `otelcol_process_uptime`); k8s_attributes
metrics keep their dotted OTel names in Prometheus (`otelcol.k8s.pod.association`,
`otelcol.k8s.watcher.pod_cache.size`, queried with the Prometheus 3 quoted-name syntax). If a collector upgrade
brings `_total` back, the queries need the suffix.

| Family | Meaning |
|--------|---------|
| `otelcol_receiver_{accepted,refused,failed}_{spans,metric_points,log_records}` | items pushed into the pipeline / rejected by back-pressure (memory_limiter) / internal errors, per receiver + transport |
| `otelcol_exporter_{sent,send_failed,enqueue_failed}_*` | delivered / lost after retries / lost because the sending queue is full |
| `otelcol_exporter_queue_size`, `_queue_capacity`, `_in_flight_requests` | sending queue fill and concurrency per exporter (capacity 2000 agent, 5000 gateway/logs) |
| `otelcol_processor_incoming_items`, `_outgoing_items{processor,otel_signal}` | per-processor throughput; the difference is what the processor dropped/filtered |
| `otelcol_processor_memory_limiter_{accepted,refused}_*` | memory_limiter decisions |
| `otelcol_processor_batch_*` | batch send size (histogram), size vs timeout triggers, metadata cardinality |
| `otelcol_fileconsumer_open_files`, `_reading_files` | file_log tailing (otel-logs) |
| `otelcol.k8s.pod.association{status}`, `otelcol.k8s.watcher.*` | k8s_attributes matching and informer cache |
| `otelcol_process_*` | CPU seconds, RSS, Go heap/sys/alloc, uptime |
| `target_info` | collector version (`service_version`) |

**Dashboard:** variable *Collector* (job); overview (collectors down, receiver refused+failed 1h, export failures
1h, max queue usage, log records sent/s, restarts, per-pod table with version/uptime/CPU/RSS/heap); one row per
signal (received vs sent; refused/failed/send-failed/enqueue-failed); processors (dropped/filtered = incoming -
outgoing, throughput, memory_limiter refusals, batch size/triggers, metadata cardinality); exporters (queue usage,
size vs capacity, in-flight); receivers and enrichment (file_log files, pod association, pod cache); resources
(CPU, RSS vs container limit, heap/alloc). Sources: [collector internal telemetry](https://opentelemetry.io/docs/collector/internal-telemetry/),
[grafana.com 15983](https://grafana.com/grafana/dashboards/15983) rev 31 (queue usage, CPU, memory, batch formulas).

**Annotations:** firing alerts in namespace `opentelemetry`, restarts, operator reconciles of collector CRs (off by
default).

**EMPTY (expected):** the whole *Traces* and *Metrics* rows (no OTLP traces/metrics are sent; on the gateway the
pipelines exist but carry nothing), *Log records: send failed / enqueue failed* and *memory_limiter refusals*
(created on the first failure/refusal).

## OpenTelemetry Operator and OBI

**opentelemetry-operator** (chart 0.129.0): reconciles OpenTelemetryCollector CRs, conversion/admission webhooks
(including `/mutate-v1-pod` for every pod creation). Job `opentelemetry-operator`, controller-runtime metrics:
`controller_runtime_reconcile_total{controller,result}`, `_reconcile_errors_total`, `_reconcile_time_seconds`,
`_webhook_requests_total{webhook,code}`, `_webhook_latency_seconds`, `workqueue_*`, `leader_election_master_status`,
`certwatcher_*`, `rest_client_requests_total` + runtime. The chart's PrometheusRule `managerRules` has
ReconcileErrors (opentelemetrycollector errors > 0 over 5m) and WorkqueueDepth (> 0).

**OBI** (chart opentelemetry-ebpf-instrumentation 0.16.1, OBI v1.0.0): no self-metrics are scraped (the chart's
internal metrics endpoint is off by default). Covered by pod CPU/memory/readiness only.

**Dashboard:** up, leader, reconcile errors 1h, work queue depth, webhook 5xx 1h, OBI pods ready, restarts;
reconciles by controller/result, reconcile p99, work queue; webhook requests by path/code, webhook p99; operator
and OBI resources. Source: [kubebuilder metrics reference](https://book.kubebuilder.io/reference/metrics-reference).

**Annotations:** firing alerts in `opentelemetry` or ReconcileErrors/WorkqueueDepth, restarts, collector reconciles.

**EMPTY (expected):** *Reconciles by controller / result* (no reconcile in the window; shown with `> 0` so idle
controllers do not clutter the legend).

**Observed:** controller-runtime pre-creates `code="500"` webhook series for every path; they stayed at 0 over the
last 7 days (no webhook error).

---

## Gaps and recommendations

Needs the owner / another group (not changed here):

1. **Alertmanager has no receiver** (kube-prometheus-stack values, Kubernetes group): alerts are never delivered.
2. **PrometheusOperator\* alerts can never fire** (kps values): rule selector `job="kps-operator"` vs scrape job
   `prometheus-operator` (see Prometheus Operator section).
3. kube-prometheus-stack's *Prometheus / Overview*, *Alertmanager / Overview*, *Grafana Overview* duplicate part
   of these curated dashboards; keeping them is fine (reference), turning them off is optional.

Alerts added in the apps of this group:

4. **Collector** (`opentelemetry-raw/prometheus.rules.yaml`, collector docs "Use internal telemetry to monitor the
   Collector"; thresholds derived, the docs say "sustained"): `OtelCollectorExporterSendFailed`,
   `OtelCollectorExporterEnqueueFailed`, `OtelCollectorReceiverRefused` (rate of `*_spans|metric_points|log_records`
   > 0 for 10m, counters without `_total`, series appear on first failure) and `OtelCollectorExporterQueueNearlyFull`
   (`queue_size / queue_capacity > 0.8` for 10m); all warning.
5. **Tempo** (`monitoring-raw/tempo.rules.yaml`, tempo-mixin at tag v3.1.1, thresholds as upstream, `cluster` dropped,
   `job="tempo"` added): TempoLiveStoreUnhealthy, TempoCompactionsFailing, TempoBadOverrides,
   TempoUserConfigurableOverridesReloadFailing (critical), TempoBackendWorkerCallRetriesHigh (> 5/min, warning; ~1/min
   at idle).
6. **Grafana** (`monitoring-raw/grafana.rules.yaml`): grafana-mixin recording rule
   `namespace_job_handler_statuscode:grafana_http_request_duration_seconds_count:rate5m` + `GrafanaRequestsFailing`
   (> 50 % 5xx per handler for 5m, warning), as upstream.
7. **OBI internal metrics**: OBI can expose `obi_*` self-metrics (export errors, instrumented processes) via
   `extensions.obi.daemon.internal_metrics.prometheus.port` + chart `service.enabled` / `serviceMonitor.enabled`.
   Not enabled: OBI runs on the host network, so the port would listen on the node IP without authentication.
   Revisit when workloads are instrumented (or export them over OTLP if OBI supports it for Config v2).
8. **Send some telemetry**: until an app (or the VPS) sends OTLP, the traces/metrics side of the pipeline (gateway
   span metrics, Tempo, Prometheus OTLP) is untested end to end.
