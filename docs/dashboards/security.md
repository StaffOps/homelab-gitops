# Dashboards: Security & Identity

Grafana folder **Security & Identity**, files in `helm-charts/monitoring/monitoring-raw/dashboards/security/`
(one ConfigMap `dashboard-security-<name>` each, rendered by `monitoring-raw`). Every dashboard has an intro text
panel, a description on every panel (with the source of its formula), annotations for firing alerts and container
restarts plus service events, and a "Security & Identity" link menu to the others.

| Dashboard (uid) | Kind | Service |
|-----------------|------|---------|
| Vault (`hl-security-vault`) | curated | Vault |
| cert-manager (`hl-security-cert-manager`) | curated | cert-manager |
| External Secrets (`hl-security-external-secrets`) | curated | External Secrets Operator |
| External Secrets (official) (`hl-security-external-secrets-official`) | official v2.15.0, adapted | External Secrets Operator |
| Kyverno (`hl-security-kyverno`) | curated | Kyverno |
| Kyverno (official) (`hl-security-kyverno-official`) | chart 3.10.0 dashboard, vendored | Kyverno |
| Keycloak (`hl-security-keycloak`) | curated | Keycloak |
| Keycloak troubleshooting (official) (`hl-security-keycloak-troubleshooting`) | official, adapted | Keycloak |
| Keycloak capacity planning (official) (`hl-security-keycloak-capacity`) | official, adapted | Keycloak |
| Dependency-Track (`hl-security-dependency-track`) | curated | Dependency-Track |
| Dependency-Track (official) (`hl-security-dependency-track-official`) | upstream 5.2.1, adapted | Dependency-Track |

"Adapted" always means: datasource pinned to `prometheus`, intro text panel, missing panel descriptions, lab
annotations; anything else is listed per dashboard below. Validation: `scripts/check-dashboard.py` (0 errors on all
files); the EMPTY results are explained per service. The PostgreSQL clusters `keycloak-db` and `dtrack-db`
(CloudNativePG) are covered by the Databases dashboards.

Common annotations: `ALERTS{alertstate="firing", namespace="<ns>"}` (Vault and cert-manager match by alert name too,
because `VaultDown` uses `absent()` and carries no namespace) and
`changes(kube_pod_container_status_restarts_total{namespace="<ns>"}[2m]) > 0`.

---

## Vault

**Here:** `vault/vault-0`, standalone, `file` storage on `local-path`, Kubernetes auth for External Secrets (role
`external-secrets`), KV v2 at `secret/homelab/*`. Sealed after every restart; CronJob `vault-autounseal` unseals within
5 min. Scrape job `vault-internal` (chart ServiceMonitor, `/v1/sys/metrics?format=prometheus`, 60s,
`unauthenticated_metrics_access = true` on the listener — cluster-internal only, the HTTPRoute exposes the UI).

**Metrics change (pending sync + restart):** `telemetry.prometheus_retention_time` was `30s` (the example value of the
Vault docs). Vault drops a metric from `/v1/sys/metrics` when it was not updated within that time; with a 60s scrape,
every event-driven metric (request/route/token/barrier summaries, token creation counters) and every usage gauge
(updated every `usage_gauge_period` = 10 min: token counts, KV counts) vanished before Prometheus saw it — hence the
~111 series. Set to `24h` (Vault's default, [telemetry docs](https://developer.hashicorp.com/vault/docs/configuration/telemetry)).
The Vault StatefulSet uses `OnDelete`: the new config applies after `vault-0` is restarted, which seals Vault until
auto-unseal (or `scripts/vault.sh unseal`).

**Metrics (families):**
- Availability: `vault_core_unsealed` (1/0, the `VaultSealed` alert), `vault_core_active`, `up`.
- Requests: `vault_core_handle_request{quantile}`/`_count` and `vault_core_handle_login_request` (summaries, **ms**),
  `vault_core_response_status_code{type,code}` (counter), `vault_core_in_flight_requests`, per-route summaries
  `vault_route_<op>_<mount>_` (e.g. `read_secret_`, `update_auth_kubernetes_`), `vault_core_check_token`,
  `vault_core_fetch_acl_and_token`, `vault_policy_get_policy`.
- Tokens and leases: `vault_token_creation{auth_method,mount_point,creation_ttl}` (counter), `vault_token_count_by_ttl`,
  `vault_token_count_by_auth`, `vault_token_count` (usage gauges), `vault_token_create/store/lookup/revoke_tree`,
  `vault_expire_num_leases`, `vault_expire_num_irrevocable_leases` (should be 0), `vault_expire_*` timings.
- Storage: `vault_barrier_get/put/list/delete` (summaries, ms — the encryption layer over the file backend),
  `vault_cache_hit/write`, `vault_core_mount_table_num_entries/size{type,local}`, `vault_secret_kv_count{mount_point}`,
  `vault_identity_entity_count`, `vault_policy_configured_count`.
- Runtime: `vault_runtime_*` (alloc/sys bytes, goroutines, GC), Go `go_*`/`process_*`.
- Not applicable here (always 0 or absent): `vault_core_replication_*`, `vault_core_performance_standby`,
  `vault_core_leadership_*`/`step_down` (no HA), `vault_raft_*`/`vault_autopilot_*` (file storage), `vault_audit_*`
  (no audit device).

**Dashboard "Vault"** (curated; HashiCorp publishes no Grafana dashboard; the most downloaded community one,
grafana.com 12904 rev 2, dates from 2020). Built from the [vault-mixin](https://github.com/adinhodovic/vault-mixin)
(grafana.com 25314 rev 6 + `prometheus_alerts.yaml`) and the
[telemetry reference](https://developer.hashicorp.com/vault/docs/internals/telemetry/metrics), without its HA, Raft,
replication and audit panels.
- Is Vault usable?: seal status, scrape, active node, up since, auto-unseal CronJob last success (KSM
  `kube_cronjob_status_last_successful_time`, yellow > 10 min / red > 20 min — derived: the CronJob runs every 5 min and
  exits 0 when unsealed), response success rate (mixin `VaultLowResponseSuccessRate`, red < 95 %), seal state timeline.
- Requests: responses by status class, request/login rate, request latency p50/p99, requests by route (mixin "Route
  Read Rate" generalised to all operations), in-flight requests.
- Tokens, leases, secrets: token creation by auth method, live tokens by TTL (`+Inf` red: mixin
  `VaultTooManyInfinityTokens` > 3), leases/irrevocable, KV secrets stored, mounts, barrier latency p99.
- Resources: memory working set vs limit, CPU, goroutines.
- Annotations: alerts (`Vault.*` or namespace vault), restarts, **Vault sealed** (`vault_core_unsealed == 0`),
  **Vault process started** (`time() - process_start_time_seconds < 300`).
- EMPTY now (pending the retention change): request rate, request latency, token creation, live tokens by TTL, KV
  secrets stored (and intermittently route/barrier put/list). Metric names to check after the restart:
  `vault_core_handle_request_count`, `vault_core_handle_request{quantile="0.99"}`, `vault_token_creation`,
  `vault_token_count_by_ttl`, `vault_secret_kv_count`, `vault_route_read_secret___count`, `vault_barrier_put`.

**Alerts added** (`vault-raw/prometheus.rules.yaml`):
- `VaultTooManyInfinityTokens`: `vault_token_count_by_ttl{creation_ttl="+Inf"} > 3` for 5m, warning (vault-mixin, as is).
- `VaultLowResponseSuccessRate`: non-5xx share of `vault_core_response_status_code` < 95 % and > 1 5xx/s, for 1m,
  warning (vault-mixin; aggregated `by (namespace, job, instance)` to keep `namespace=vault`).
- `VaultAutoUnsealNotSucceeding`: `time() - kube_cronjob_status_last_successful_time{cronjob="vault-autounseal"} > 20 min`,
  warning (derived: the dashboard's red threshold; the CronJob runs every 5 min). Catches a missing `vault-unseal` Secret
  before the next reboot.

**Gaps:** volume usage cannot be shown per volume:
`local-path` volumes report the node filesystem (use the node dashboards).

## cert-manager

**Here:** v1.21.3, ClusterIssuers `letsencrypt-prod`/`letsencrypt-staging` (ACME DNS-01 on Cloudflare, token from
Vault via ExternalSecret `cert-manager/cloudflare-api-token`), Certificate `gateway/wildcard` (`*.staffops.space`), plus
the OpenTelemetry operator's self-signed Issuer/Certificate. Jobs `cert-manager` (controller), `webhook`, `cainjector`.
Lab alerts: `CertificateNotReady` (not True for 30m), `CertificateExpiringSoon` (< 14 days), plus the mixin's
`CertManagerAbsent` and `CertManagerHittingRateLimits`.

**Metrics (families):**
- Certificates: `certmanager_certificate_ready_status{condition}`, `certmanager_certificate_expiration_timestamp_seconds`,
  `_not_after_`/`_not_before_timestamp_seconds` (notBefore changes on every issuance), `_renewal_timestamp_seconds`
  (when cert-manager will renew).
- Issuers: `certmanager_clusterissuer_ready_status`, `certmanager_issuer_ready_status`.
- ACME: `certmanager_http_acme_client_request_count{action,host,method,status}`,
  `certmanager_http_acme_client_request_duration_seconds` (summary).
- Controller: `certmanager_controller_sync_call_count{controller}`, `certmanager_controller_sync_error_count`,
  `certmanager_clock_time_seconds(_gauge)`; Venafi metrics (unused).
- webhook/cainjector: controller-runtime `controller_runtime_webhook_*`, `controller_runtime_reconcile_*`,
  `workqueue_*`, `certwatcher_*`, `leader_election_master_status`, `rest_client_requests_total`.

**Official dashboard:** cert-manager's docs point to the [cert-manager-mixin](https://github.com/imusmanmalik/cert-manager-mixin)
(rendered JSON: monitoring-mixins/website `assets/cert-manager/dashboards/cert-manager-overview.json`, commit
d4478eb0ca). Not imported as is: the generated JSON has a template variable with an empty name
(`label_values(certmanager_certificate_ready_status, )`), groups ACME requests by a `path` label that v1.21 does not
have, and uses kube-state-metrics v1 names (`kube_pod_container_resource_limits_cpu_cores`) removed in KSM v2.

**Dashboard "cert-manager"** (curated, mixin queries; range 7 days):
- Certificates: count by Ready condition, soonest expiry (mixin; red < 14 d = lab alert, yellow < 30 d = Let's Encrypt
  renewal window), issuers ready, components up (mixin `CertManagerAbsent`), table (ready, issuer, expiry, planned
  renewal), time to expiry per certificate with 14/30-day lines.
- ACME and controller: requests by action/status (mixin), average duration (mixin), non-2xx in 24 h, 429 in 24 h (mixin
  `CertManagerHittingRateLimits`), controller sync errors and sync rate (mixin).
- Webhook and cainjector: webhook requests by code, webhook p99, cainjector reconcile errors.
- Resources: memory vs limit (KSM v2 names), CPU.
- Annotations: alerts, restarts, **Certificate issued/renewed** (`changes(certmanager_certificate_not_before_timestamp_seconds[10m]) > 0`).
- EMPTY: none at validation time (error panels return zero-valued series).

**Alerts added** (`cert-manager-raw/prometheus.rules.yaml`, mixin = cert-manager-mixin):
- `CertManagerAbsent`: `absent(up{job="cert-manager"})` for 10m, critical (mixin, static `namespace: cert-manager`).
- `CertManagerHittingRateLimits`: ACME `status="429"` rate > 0 for 5m, critical (mixin; `by (namespace, host)`).
- `CertificateNotReady` now matches `condition!="True"` (mixin `CertManagerCertNotReady` matcher, so `Unknown` is caught);
  the lab's 30m / warning are kept and the summary shows the Certificate's own namespace (`exported_namespace`).

## External Secrets Operator

**Here:** v2.15.0, `ClusterSecretStore vault` (Kubernetes auth) and one ExternalSecret per consumer (argo, cert-manager,
external-dns, keycloak, dependency-track, monitoring, opentelemetry, velero, mcp-servers, llm), `refreshInterval: 1h`.
Jobs `external-secrets-metrics` (controller), `external-secrets-webhook`, `external-secrets-cert-controller-metrics`.
The scrape sets `namespace=external-secrets`; the object's namespace is `exported_namespace`.

**Metrics** ([docs v2.15.0](https://github.com/external-secrets/external-secrets/blob/v2.15.0/docs/api/metrics.md)):
- `externalsecret_status_condition{condition,status}` and `clustersecretstore_status_condition` (gauges, 1 on the
  current condition), `externalsecret_reconcile_duration` / `clustersecretstore_reconcile_duration` (gauges in
  **nanoseconds**: Go `time.Duration`), `externalsecret_sync_calls_total`, `externalsecret_sync_calls_error` (only after
  the first error), `externalsecret_provider_api_calls_count{provider,call,status}` (Vault: Login, ReadSecretData,
  LookupSelf, RevokeSelf).
- controller-runtime: `controller_runtime_reconcile_total{controller,result}`, `_reconcile_errors_total`,
  `_reconcile_time_seconds`, `_active_workers`, `workqueue_*`, `controller_runtime_webhook_requests_total{code}`,
  `_webhook_latency_seconds`, `certwatcher_read_certificate_*`.
- Per-ExternalSecret series are created when an object is reconciled: right after an ESO restart some are missing
  until their next refresh (up to 1 h).

**Dashboard "External Secrets (official)"** — [docs/snippets/dashboard.json @ v2.15.0](https://github.com/external-secrets/external-secrets/blob/v2.15.0/docs/snippets/dashboard.json).
Changes: SecretStore / ClusterExternalSecret / PushSecret error gauges removed (kinds not used here), `namespace` →
`exported_namespace` in "Not Ready ExternalSecrets" and "sync call errors" (otherwise they group everything under
`external-secrets`). EMPTY: the error-rate gauges end with `> 0` (empty = no errors), provider errors, not-ready table,
sync errors — all "no errors in the window".

**Dashboard "External Secrets"** (curated; ESO metrics docs + its SLI section + official panels):
- Store READY, Vault seal status (dependency), ExternalSecrets Ready / NOT Ready, Vault API errors (1 h), components up,
  per-ExternalSecret table (Ready, last reconcile seconds, syncs in 24 h).
- Sync activity: Vault API calls by call/status, sync errors per ExternalSecret, reconcile errors, reconcile p99 and
  workqueue depth (ESO SLIs).
- Webhook (requests by code, p99 — ESO SLIs) and cert-controller errors; resources.
- Annotations: alerts (namespace or `VaultSealed`), restarts, **ExternalSecret not Ready**, **Vault sealed**.
- EMPTY: "Sync errors per ExternalSecret" (`externalsecret_sync_calls_error` exists only after an error).

**Alerts added** (`external-secrets-raw/prometheus.rules.yaml`; ESO ships no rules, metric semantics from the docs):
- `ExternalSecretNotReady`: `externalsecret_status_condition{condition="Ready",status="False"} == 1` for 15m, warning.
- `ClusterSecretStoreNotReady`: same on `clustersecretstore_status_condition`, for 15m, warning (derived, same duration).

## Kyverno

**Here:** v1.20.0 (chart 3.10.0), 4 controllers, admission on every namespace with `failurePolicy: Ignore`; 12 PSS
baseline `ValidatingPolicies` in Audit (`kyverno-policies`), `MutatingPolicy pod-zone-label`, `GeneratingPolicy
mcp-read-crds`, CronJob `pod-zone-label-sweeper` (every 5 min). Jobs `kyverno-svc-metrics` (admission),
`kyverno-background-controller-metrics`, `kyverno-cleanup-controller-metrics`, `kyverno-reports-controller-metrics`.

**Metrics** ([reference](https://kyverno.io/docs/reference/metrics/)):
- Admission: `kyverno_admission_requests_total{request_allowed,request_webhook,resource_kind,resource_namespace,
  resource_request_operation}`, `kyverno_admission_review_duration_seconds` (histogram), `kyverno_http_requests_*`
  (per webhook URL).
- Policy results/latency (CEL policy types): `kyverno_validating_policy_results_total{policy_name,result,
  execution_cause,policy_validation_mode,resource_*}` and `_execution_duration_seconds`, same for `mutating_` and
  `generating_` (`image_validating_`/`deleting_` absent: no such policies).
- Controllers: `kyverno_controller_reconcile_total{controller_name}`, `kyverno_controller_requeue_total` /
  `_drop_total` (only after requeues/drops), `kyverno_client_queries_total`, `kyverno_updaterequest_total` (gauge),
  `kyverno_breaker_total` (reports circuit breaker invocations; undocumented beyond its HELP text — not charted),
  `kyverno_ttl_controller_info`, `kyverno_legacy_policies_total` (0: no ClusterPolicy left),
  `kyverno_globalcontextentry_projection_language`, `kyverno_info{version}`.
- Most of the ~6.4k series are the per-policy/per-resource results and execution buckets of the admission and
  reports controllers.

**Dashboard "Kyverno (official)"** — the chart's own dashboard (`charts/grafana/dashboard/kyverno-dashboard.json` in
chart 3.10.0). Previously deployed by the chart into the General folder; now `grafana.enabled: false` and the JSON is
vendored (the chart ConfigMap supports annotations, but pruning needs a copy). Changes: `cluster` variable removed
(no `cluster` label here), ImageValidatingPolicy stat and per-policy latency target removed, DeletingPolicy row removed.
EMPTY: "Enforcing (Deny) Validating Policies" until a policy is moved to Enforce.

**Dashboard "Kyverno"** (curated):
- Health: controllers up, admission p99 (chart example alerts: > 1 s warning, > 5 s critical), denied requests in 24 h
  (must be 0 in Audit), audit findings in 24 h, sweeper last success (derived: yellow 15 min, red 30 min).
- Admission: latency p50/p95/p99 with 1 s / 5 s lines (monitoring guide), requests by webhook and allowed.
- Policy results: findings by policy, top namespaces with findings (24 h), pod-zone-label results, mcp-read-crds
  results, policy execution p99 by kind (chart example alert 0.5 s).
- Controllers: reconcile and drop rate (reference "useful queries"), UpdateRequests pending, API queries by controller.
- Resources: memory vs limit, CPU.
- Annotations: alerts, restarts, **Sweeper Job failed** (`kube_job_status_failed`).
- EMPTY: the drop series (`kyverno_controller_drop_total` appears only after a drop).

**Gaps / recommendations:** enable the chart's `prometheusRule` with its example rules (admission p99 > 1 s / > 5 s,
policy execution p99 > 0.5 s) — they are already the dashboard thresholds. PolicyReport contents (which resource fails
which rule) are not metrics: `kubectl get policyreports -A` or Policy Reporter if wanted.

## Keycloak

**Here:** 26.8.2 (codecentric keycloakx 7.4.0), 1 replica, `KC_CACHE=local`, realm `staffops`, database `keycloak-db`
(CloudNativePG). Job `keycloak-http` (management port 9000).

**Metrics change (pending sync):** before, only `metrics-enabled` was on: no latency histogram (no
`http_server_requests_seconds_bucket`) and no user-event metrics. Added to `helm-charts/keycloak` (`extraEnv`):
`KC_HTTP_METRICS_HISTOGRAMS_ENABLED=true` and `KC_HTTP_METRICS_SLOS=250` (the 250 ms bucket the SLI guide needs),
`KC_EVENT_METRICS_USER_ENABLED=true` with `KC_EVENT_METRICS_USER_TAGS=realm,clientId` (feature `user-event-metrics` is
enabled by default). Expected extra series: ~70 buckets × the ~20–30 URI/status combinations (~2k) plus a few hundred
event counters. Metric names to check: `http_server_requests_seconds_bucket{le="0.25"}`, `keycloak_user_events_total`.
The StatefulSet rolls on sync (short login outage). Docs: [metrics](https://www.keycloak.org/observability/configuration-metrics),
[event metrics](https://www.keycloak.org/observability/event-metrics).

**Metrics (families):** HTTP (`http_server_requests_seconds{uri,method,status,outcome}`, `http_server_active_requests`,
`http_server_bytes_*`, `http_server_connections_*`); Keycloak (`keycloak_user_events_total{realm,client_id,event,error}`,
`keycloak_credentials_password_hashing_validations_total{realm,algorithm,outcome}`, `keycloak_expiration_*`,
`keycloak_session_expiration_task_seconds`); DB pool `agroal_*` (active, available, awaiting, acquire/creation/leak);
Infinispan local caches `vendor_statistics_*{cache}` (realms, users, keys, authorization, sessions, crl, …),
`vendor_cache_container_*`, `vendor_lock_manager_*`, `vendor_transactions_*`; Caffeine `cache_*`; JVM `jvm_*`, Netty
`netty_*`, Vert.x `worker_pool_*`, `system_*`, `process_*`. Cluster/JGroups metrics do not exist (local caches).

**Official dashboards:** [keycloak/keycloak-grafana-dashboard](https://github.com/keycloak/keycloak-grafana-dashboard)
at commit f819507c13 (branch `main`, the one the [Keycloak guide](https://www.keycloak.org/observability/grafana-dashboards)
lists for Keycloak ≥ 26.3).
- **Keycloak troubleshooting (official)**: removed the *Cluster Metrics* and *Clustered caching* rows
  (JGroups/replication, single node with local caches) and *KUBERNETES - CPU Usage percentage* (divides by a CPU limit;
  none is set); `namespace` variable scoped to `up{job="keycloak-http"}`; fixed the DB pool panel's `job` filter
  (upstream expects `keycloak-metrics|keycloak-service`). EMPTY (pending histograms): Responses below 250ms, both
  "Changes in %" panels (no SERVER_ERROR on auth endpoints is also a reason), request heatmap.
- **Keycloak capacity planning (official)**: `realm` variable taken from a Keycloak metric (multi, All). EMPTY: all
  event panels (pending event metrics); Token Exchange stays empty (no client uses token exchange).

**Dashboard "Keycloak"** (curated):
- Service level ([SLI guide](https://www.keycloak.org/observability/keycloak-service-level-indicators) formulas over
  the selected range): up, availability (SLO 99.9 %), auth requests < 250 ms (SLO 95 %), auth server errors
  (SLO < 0.1 %), DB connections waiting.
- Logins and tokens (capacity planning queries): user events by type, failed events by error, failed events by client
  (1 h), password validations by outcome.
- HTTP: requests by URI and outcome (probes excluded), auth latency p50/p95/p99 with the 250 ms line.
- Database pool and JVM: Agroal active/idle/waiting, heap vs max and container vs limit, GC overhead and CPU.
- Annotations: alerts, restarts, **Realm import Job running** (Argo CD PostSync `keycloak-realm-import`).
- EMPTY (pending sync): auth requests < 250 ms, the three user-event panels, auth latency.

**Alerts added** (`keycloak-raw/prometheus.rules.yaml`):
- `KeycloakAuthErrorBudgetBurn`: `SERVER_ERROR` share of authentication requests (SLI guide query and URI regex, recorded
  as `keycloak:auth_server_error_ratio:rate{5m,30m,1h,6h}`) against the guide's 0.1 % SLO with the SRE-workbook
  multiwindow burn rates: > 14.4x over 1h and 5m (critical), > 6x over 6h and 30m (warning). Derived (no upstream rule).

**Not added:** availability alert (the SLI is `up`: kube-prometheus-stack `TargetDown` / `KubeStatefulSetReplicasMismatch`
already cover it); burst of `invalid_user_credentials` (no upstream threshold; Keycloak's brute-force detection is the
control — revisit with a measured baseline once `keycloak_user_events_total` exists).

## Dependency-Track

**Here:** 5.2.1 (chart 2.9.0), API server monolith + static frontend (no metrics), PostgreSQL `dtrack-db`, OIDC via
Keycloak. Job `dependency-track-api-server-metrics` (management port 9000, `dt.metrics.enabled` by the chart). Many
meters are created lazily: HTTP metrics appear after the first API request since the pod start, DEX queue/run metrics
when workflows run.

**Metrics (families, ~5k series):** `dt_info{version}`; DEX workflow engine `dt_dex_engine_*` (runs completed/current
by workflow and status, task queue capacity/depth, scheduling and poll latency histograms, worker concurrency
utilization, backpressure skips, buffers, leadership); notifications outbox `dt_outbox_relay_*`; db-scheduler
`dbscheduler_task_completions_total{task,result}`, `_task_duration_seconds` (histogram, the largest family),
`_task_last_run_timestamp_seconds` (0 = not run since start), `_task_last_run_duration`; resilience4j circuit breakers
on DEX buffers `resilience4j_circuitbreaker_*`; DB `hikaricp_*`, `jdbi_query_latency_seconds{query,outcome}`,
`datanucleus_*`; HTTP `http_server_requests_seconds{uri,status,outcome}` and `http_client_requests_seconds`; caches
`cache_*`; JVM/process `jvm_*`, `process_*`, `executor_*`, `system_*`.

**Official dashboards:** DT publishes no dashboard on grafana.com; its repository ships dev dashboards at
[`dev/monitoring/grafana/dashboards` @ 5.2.1](https://github.com/DependencyTrack/dependency-track/tree/5.2.1/dev/monitoring/grafana/dashboards)
(overview, database, dex, notifications, cache, runtime).
- **Dependency-Track (official)** = `apiserver-overview.json` (descriptions upstream); removed "Vulnerability Policy
  Evaluation Latency" (`vuln_policy_evaluation_seconds` never seen: no vulnerability policies). EMPTY: HTTP latency
  panel (no API request since the last restart), "DEX Workflow Runs By Status" (gauge exists while workflows run).
- The other five are not imported: their useful panels are in the curated view.

**Dashboard "Dependency-Track"** (curated from the six upstream dashboards):
- Health: up, version/uptime, HTTP 5xx ratio (overview), scheduled task failures 24 h (overview), circuit breakers not
  closed (resilience4j).
- Background work: scheduled tasks table (last run, duration, failures), workflow runs completed by workflow/status
  (dex), worker concurrency utilization (dex), polls skipped by backpressure (dex), breaker rejections and outbox cycles
  (resilience4j, notifications).
- API: requests by status class, latency p50/p95/p99 (overview).
- Database and JVM: HikariCP pool, DB errors (pool timeouts, JDBI and DataNucleus failures — database dashboard), heap
  and container memory.
- Annotations: alerts, restarts, **Vulnerability mirror completed** (`increase(dbscheduler_task_completions_total{task=~".*Mirror",result="ok"}[5m]) > 0`).
- EMPTY: the three HTTP panels (lazy meters, see above), "JDBI failures" series (no failed query).

**Gaps / recommendations:** no PrometheusRule exists for DT; candidates: scheduled task failures, a mirror task with no
success for > 48 h, circuit breaker open.

---

## Changes outside the dashboards (in this group's apps)

| File | Change | Effect |
|------|--------|--------|
| `helm-charts/vault/vault/values.yaml.gotmpl` | `prometheus_retention_time` 30s → 24h | full Vault telemetry, after a `vault-0` restart (seals Vault until auto-unseal) |
| `helm-charts/keycloak/keycloak/values.yaml.gotmpl` | HTTP histograms + 250 ms SLO bucket, user event metrics (realm, clientId) | SLI latency and login panels; Keycloak restarts on sync |
| `helm-charts/kyverno/kyverno/values.yaml.gotmpl` | `grafana.enabled: false` | chart ConfigMap `monitoring/kyverno-grafana-grafana` pruned; replaced by `kyverno-official.json` |

No change was requested for the CloudNativePG `Cluster` objects in `keycloak-raw` / `dependency-track-raw`.
