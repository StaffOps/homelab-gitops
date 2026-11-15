# Dashboards: Networking & Ingress

Grafana folder **Networking & Ingress**, files in `helm-charts/monitoring/monitoring-raw/dashboards/networking/` (one
ConfigMap `dashboard-networking-<name>` each, rendered by `monitoring-raw`).

| Dashboard | uid | File | Kind |
|-----------|-----|------|------|
| Ingress / Gateway | `hl-networking-gateway` | `networking/gateway.json` | curated |
| Mesh / istiod & ztunnel | `hl-networking-mesh` | `networking/mesh.json` | curated |
| Calico dataplane | `hl-networking-calico` | `networking/calico.json` | curated |
| MetalLB & external-dns | `hl-networking-metallb-external-dns` | `networking/metallb-external-dns.json` | curated (no official dashboard) |
| Istio Control Plane (official) | `hl-networking-istio-control-plane` | `networking/istio-control-plane.json` | official, Istio 1.30.8 |
| Istio Ztunnel (official) | `hl-networking-istio-ztunnel` | `networking/istio-ztunnel.json` | official, Istio 1.30.8 |
| Istio Mesh (official) | `hl-networking-istio-mesh` | `networking/istio-mesh.json` | official, Istio 1.30.8 |
| Calico Felix (official) | `hl-networking-calico-felix` | `networking/calico-felix.json` | official, Calico v3.33.0 |
| Calico Typha (official) | `hl-networking-calico-typha` | `networking/calico-typha.json` | official, Calico v3.33.0 |

Start with the four curated dashboards; the official ones are kept as reference for deeper digging.

Every dashboard has a "How to read this dashboard" text panel, a description on every panel (with the formula
source) and annotations: firing alerts of the service's namespaces/alert names, container restarts, plus service
events (gateway LDS config pushes, wildcard certificate renewals, Istio config changes, Felix datastore resyncs,
MetalLB gratuitous-ARP announcements, external-dns record changes).

Validated with `scripts/check-dashboard.py` against the live Prometheus: **0 errors** on all nine files. Loki
targets (gateway access logs) are skipped by the tool and were run by hand against the Loki API (all succeed).
Every EMPTY result is listed under its service below.

Versions in the cluster (image tags): Calico `v3.33.0` (tigera-operator `v1.44.0`), Istio `1.30.8` (istiod,
ztunnel, istio-cni, proxyv2 gateways), MetalLB `v0.16.2`, external-dns `v0.23.0`.

---

## Istio Gateways (`public`, `mcp`)

**What it does here.** Gateway API `Gateway` objects in namespace `gateway` (helm-charts/gateway) are deployed by
istiod as Envoy Deployments: `public-istio` (192.168.68.240, every `*.staffops.space` HTTPS host, http→https 301)
and `mcp-istio` (192.168.68.241, only `mcp.staffops.space`, RequestAuthentication + two DENY AuthorizationPolicies
that require a Keycloak JWT with group `/mcp/admin` or `/mcp/viewer`). TLS is terminated with the cert-manager
Certificate `gateway/wildcard`. Access logs are JSON on stdout (istiod `meshConfig.accessLogEncoding: JSON`) and
reach Loki through otel-logs.

**Scrape.** PodMonitor `gateway-envoy` (helm-charts/istio/istio-raw), job `istio-system/gateway-envoy`, port 15090
`/stats/prometheus`, 30 s. **Both gateways are scraped** (`up` = 1 for `public-istio-*` and `mcp-istio-*`), ~3.5k
series.

| Family | Meaning / use |
|--------|---------------|
| `istio_requests_total` | requests by `source_workload` (gateway), `destination_service_*` (backend), `response_code`, `response_flags`; `reporter="source"`. **No host/route label**: the curated dashboard splits by backend Service (1:1 with hostnames here) and uses Loki for host/route |
| `istio_request_duration_milliseconds_*`, `istio_request_bytes_*`, `istio_response_bytes_*` | histograms (20 buckets) → latency percentiles |
| `envoy_http_rbac{authz_enforce_result}` | RBAC filter allowed/denied (only on mcp-istio, from the AuthorizationPolicies) |
| `envoy_server_*` | `live`, `state` (0 = LIVE), `uptime`, `total_connections` (downstream), `memory_*`, `watchdog_*`, `concurrency`. `days_until_first_cert_expiring` reads **0** for both gateways (SDS-delivered certs are not counted) → not used; cert expiry comes from cert-manager |
| `envoy_cluster_manager_*`, `envoy_listener_manager_*` | CDS/LDS updates: `*_update_success`, `*_update_rejected` (config NACKed), active/warming clusters & listeners |
| `envoy_cluster_*{cluster_name="xds-grpc"}` | the gateway's own connection to istiod (Istio's default stats inclusion keeps only this cluster) |
| `envoy_workload_discovery_*` | ambient workload discovery (WDS) updates |
| `istio_build` | version |

By default Istio drops every per-backend Envoy cluster stat (`cluster.outbound|…`) and the listener TLS stats.
**Enabled now (pending):** istiod `meshConfig.defaultConfig.proxyStatsMatcher` in `helm-charts/istio/istiod`
adds, for each backend cluster, `membership_healthy`, `membership_total`, `upstream_cx_connect_fail`,
`upstream_cx_connect_timeout`, `upstream_rq_timeout`, `upstream_rq_retry`, `upstream_rq_pending_overflow`, and
listener `ssl.handshake` / `ssl.connection_error` ([Istio: Envoy statistics](https://istio.io/latest/docs/ops/configuration/telemetry/envoy-stats/)).
Each gateway has ~148 clusters (every Service of the cluster), so the list is restricted to what the dashboard
uses: ~2k extra series. Proxy config is read at start: after the sync, restart both gateway Deployments once
(`kubectl --context k8s01 -n gateway rollout restart deploy/public-istio deploy/mcp-istio`). Metric names to check
afterwards: `envoy_cluster_membership_healthy{cluster_name=~"outbound.*"}`, `envoy_cluster_upstream_cx_connect_fail`,
`envoy_cluster_upstream_rq_timeout`, `envoy_listener_ssl_handshake{listener_address="0.0.0.0_443"}`.

**Dashboard `Ingress / Gateway`** (variable `gateway` = Deployments in namespace gateway, multi/All):

- Overview: gateway pods `up`; requests/s; success rate (non-5xx) and 5xx/s; p95 latency; wildcard certificate days
  left, Ready, next renewal (`certmanager_certificate_*{exported_namespace="gateway",name="wildcard"}`); LoadBalancer IP
  (kube-state-metrics); active downstream connections; config rejected by Envoy in the range.
- Traffic by backend: requests/s by gateway × status code; requests/s by backend; 5xx ratio by backend; 4xx by
  backend × code; p95 latency by backend; backends summary table (requests, success rate, p95 over the range).
- Upstream health: Envoy response flags by backend; healthy endpoints of routed backends*; connect failures &
  timeouts*; request timeouts, retries, overflow* (* pending scrape).
- TLS & client connections: TLS handshakes vs errors*; downstream connections per gateway.
- mcp Gateway authorization: RBAC allowed/denied; 401/403 per MCP backend.
- Access logs by host (Loki): requests by host (`authority`), p95 `duration` by host, errors table by host/route/
  status/flags over the range, raw failing request lines.
- Gateway proxy health: xDS connection to istiod, LDS/CDS updates applied, memory & CPU of `istio-proxy`.

Formula sources: success rate, latency percentiles and the success thresholds (red < 95 %, yellow < 100 %) come from
the official Istio Mesh dashboard ([istio-mesh.libsonnet @1.30.8](https://github.com/istio/istio/blob/1.30.8/manifests/addons/dashboards/istio-mesh.libsonnet));
metric semantics from [Istio standard metrics](https://istio.io/latest/docs/reference/config/metrics/), Envoy
[cluster](https://www.envoyproxy.io/docs/envoy/latest/configuration/upstream/cluster_manager/cluster_stats),
[listener/TLS](https://www.envoyproxy.io/docs/envoy/latest/configuration/listeners/stats),
[server](https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/statistics),
[RBAC](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/rbac_filter#statistics) stats and
[response flags](https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage#config-access-log-format-response-flags);
certificate thresholds from the cert-manager rule `CertificateExpiringSoon` (14 days) and Let's Encrypt renewal at
30 days left; LogQL from the [Loki metric queries](https://grafana.com/docs/loki/latest/query/metric_queries/) docs.
The "healthy endpoints of routed backends" query maps `cluster_name` (`outbound|<port>||<svc fqdn>`) to the
`destination_service` label with `label_replace` and keeps only backends with gateway traffic in the last hour —
derived from the documented label formats.

EMPTY now: healthy endpoints, connect failures/timeouts, request timeouts/retries/overflow, TLS handshakes/errors
(all pending the stats matcher + gateway restart). After that, connect failures, timeouts, retries, overflow and TLS
errors stay empty/zero while nothing fails.

---

## istiod, ztunnel, istio-cni (Istio ambient)

**What it does here.** Istio 1.30.8 in ambient profile (helm-charts/istio): istiod (control plane + mesh CA),
ztunnel (per-node L4 proxy), istio-cni (redirects enrolled pods' traffic into ztunnel). xDS clients today: the two
gateway Envoys and ztunnel (`pilot_xds` = 3).

**Scrape.** ServiceMonitor `istiod` → job `istiod` (port http-monitoring 15014, ~340 series); PodMonitor `ztunnel` →
job `istio-system/ztunnel` (15020 `/stats/prometheus`); **new** PodMonitor `istio-cni` → job `istio-system/istio-cni`
(port `metrics` 15014, pending sync).

**Why ztunnel has only ~19 series.** No namespace carries `istio.io/dataplane-mode=ambient`, so ztunnel proxies no
workload (`workload_manager_active_proxy_count` = 0). ztunnel exports traffic metrics (`istio_tcp_connections_*`,
`istio_tcp_sent/received_bytes_total`, `istio_tcp_sockets_open`, `istio_dns_requests_total`, …) only for traffic it
carries. Both `/metrics` and `/stats/prometheus` on 15020 return the same 10 families — nothing else to enable. They
appear as soon as a namespace is enrolled ([add workloads](https://istio.io/latest/docs/ambient/usage/add-workloads/)).

| Component | Families | Meaning / use |
|-----------|----------|---------------|
| istiod | `pilot_xds` | connected proxies |
| | `pilot_xds_pushes{type}`, `pilot_xds_push_time_*`, `pilot_xds_config_size_bytes_*`, `pilot_xds_send_time_*` | pushes and their cost |
| | `pilot_total_xds_rejects`, `pilot_total_xds_internal_errors`, `pilot_xds_expired_nonce` | NACKed config / errors (rejects & internal errors only exist after the first occurrence) |
| | `pilot_proxy_convergence_time_*`, `pilot_proxy_queue_time_*`, `pilot_debounce_time_*`, `pilot_pushcontext_init_seconds_*` | config propagation latency |
| | `pilot_k8s_cfg_events`, `pilot_k8s_reg_events`, `pilot_push_triggers` | what triggers pushes |
| | `pilot_conflict_*`, `pilot_eds_no_instances`, `pilot_k8s_endpoints_with_no_pods`, `pilot_duplicate_envoy_clusters`, `pilot_vservice_dup_domain`, `pilot_no_ip`, `endpoint_no_pod` | config inconsistencies |
| | `galley_validation_passed/failed` | validating webhook (failed only after a rejection) |
| | `citadel_server_csr_count`, `citadel_server_success_cert_issuance_count`, `citadel_server_root_cert_expiry_*` | mesh CA |
| | `pilot_services`, `pilot_virt_services`, `pilot_info`, `istiod_uptime_seconds`, `istiod_managed_clusters`, `grpc_server_*`, `go_*`, `process_*` | inventory/runtime |
| ztunnel | `istio_xds_message_total{url}`, `istio_xds_message_bytes_total`, `istio_xds_connection_terminations_total{reason}` | xDS from istiod |
| | `workload_manager_active/pending_proxy_count`, `workload_manager_proxies_started/stopped_total` | enrolled workloads |
| | `process_open_fds`, `process_max_fds`, `istio_build` | runtime |
| istio-cni | `istio_cni_install_ready`, `istio_cni_installs_total{result}`, `ztunnel_connected`, `nodeagent_reconcile_events_total{type}` | CNI plugin installed, CNI agent ↔ ztunnel link, pod reconciliation |

**Dashboard `Mesh / istiod & ztunnel`**: overview (istiod up, connected proxies, xDS rejects in range, push
convergence p99, ztunnel up, ambient workloads active/pending, mesh root CA days left); istiod (pushes by type, push
errors & rejects, convergence p50/p99, config & registry events, webhook validation, config problems detected,
certificates issued, memory/CPU, push queue p99); ztunnel (xDS messages, xDS terminations, FDs, TCP connections,
bytes by destination, memory/CPU); istio-cni (install ready, CNI agent ↔ ztunnel, reconcile events). Formulas follow
the official Control Plane and Ztunnel dashboards
([pilot.libsonnet](https://github.com/istio/istio/blob/1.30.8/manifests/addons/dashboards/pilot.libsonnet),
[ztunnel.libsonnet](https://github.com/istio/istio/blob/1.30.8/manifests/addons/dashboards/ztunnel.libsonnet)) and the
[pilot-discovery metrics reference](https://istio.io/latest/docs/reference/commands/pilot-discovery/#metrics).
Thresholds: connected proxies green at 3 (the lab's expected clients); root CA red < 90 d, yellow < 365 d (lab
planning horizon for a CA rotation, default root lifetime is 10 years).

EMPTY: push rejects by type (no reject so far; internal errors uses `or vector(0)`), ztunnel TCP connections and
bytes (no ambient workloads), the three istio-cni panels (pending the new PodMonitor).

**Official dashboards** — from [istio/istio@1.30.8 manifests/addons/dashboards](https://github.com/istio/istio/tree/1.30.8/manifests/addons/dashboards)
(same content as grafana.com 7645 / 21306 / 7639, whose revisions are not tied to an Istio version):

- *Istio Control Plane* (`pilot-dashboard.gen.json`): kept whole except the **Injection** panel (sidecar injection
  does not exist in ambient). `app="istiod"` → `job="istiod"` (the ServiceMonitor adds no `app` label). EMPTY:
  Push Errors (no rejects), Validation failed (no failures).
- *Istio Ztunnel* (`ztunnel-dashboard.gen.json`): `app="ztunnel"` → `job="istio-system/ztunnel"`. EMPTY until
  ambient enrolment: Connections, Bytes Transmitted, DNS Request, the socket queries of Resource Usage.
- *Istio Mesh* (`istio-mesh-dashboard.gen.json`): reporter `source|waypoint` → here only the gateways, so it repeats
  ingress traffic per destination workload. Dashboard links / table data links to the Service and Workload
  dashboards removed. EMPTY: TCP Workloads (no ambient workloads).
- Not vendored: *Istio Service* and *Istio Workload* (their panels filter on `connection_security_policy="mutual_tls"`
  and `reporter="destination"`, which only sidecars/waypoints produce: almost every panel would be empty here),
  *Performance* (sidecar resource usage per 1k rps), *Wasm Extension* (no Wasm plugins). Revisit Service/Workload if
  waypoints are deployed.

---

## Calico (Felix, Typha, kube-controllers, tigera-operator)

**What it does here.** Installed by Ansible (`homelab-ansible`) through tigera-operator v1.44.0, Calico v3.33.0.
Dataplane **iptables** (FelixConfiguration `bpfEnabled: false`, `nftablesMode: Disabled`; nft metrics only show the
`arp` table). Also running: calico-webhooks, calico-apiserver component, goldmane + whisker (flow logs UI).

**Scrape** (defined in `monitoring-raw/values.yaml.gotmpl`, owned by monitoring): `calico-felix` (PodMonitor,
hostNetwork :9091, ~400 series), `calico-typha` (ServiceMonitor :9093, ~450), `calico-kube-controllers`
(ServiceMonitor :9094, ~320), `tigera-operator` (PodMonitor :9484, ~1.5k). The Calico image registers every family in
every component (zero-valued `felix_*`/`typha_*`/`goldmane_*` copies in kube-controllers and typha), so every query
filters on `job`.

| Component | Families | Meaning / use |
|-----------|----------|---------------|
| Felix | `felix_resync_state` | 1 waiting for datastore, 2 resyncing, 3 in sync |
| | `felix_int_dataplane_apply_time_seconds` (summary), `felix_calc_graph_update_time_seconds` (summary), `felix_int_dataplane_failures` | policy programming latency and failures |
| | `felix_iptables_restore/save_errors`, `felix_ipset_errors`, `felix_iptables_rules{table}`, `felix_iptables_chains`, `felix_ipsets_calico/total`, `*_calls`, `*_lines_executed` | iptables/ipset subprocesses |
| | `felix_active_local_endpoints/policies/selectors`, `felix_cluster_num_*` | what the node enforces / data model size |
| | `felix_route_table_*` | route programming |
| | `felix_resyncs_started`, `felix_log_errors`, `felix_logs_dropped` | resyncs, error logs (47 error lines since start, 5 dataplane failures in 6 h: transient, alert did not fire) |
| | `felix_nflog_*`, `felix_collector_*` | flow-log collector feeding goldmane |
| | `felix_bpf_*`, `felix_nft_*` | eBPF/nftables dataplanes: zero here |
| Typha | `typha_connections_streaming{syncer}`, `typha_connections_active/accepted/dropped/grace_used` | clients (calico-node syncers felix, node-status, tunnel-ip-allocation; bgp 0) |
| | `typha_client_latency_secs`, `typha_ping_latency`, `typha_client_write_latency_secs`, `typha_next_breadcrumb_latency_secs` | client lag |
| | `typha_cache_size`, `typha_breadcrumb_*`, `typha_snapshot_*`, `typha_updates_*`, `typha_kvs_per_msg` | cache internals |
| kube-controllers | `ipam_allocations_in_use`, `ipam_ippool_size`, `ipam_blocks(_per_node)`, `ipam_allocations_borrowed`, `ipam_allocations_gc_candidates`, `ipam_ippool_reserved` | IP pool `default-ipv4-ippool` (65 536 addresses, 65 used, 2 blocks) |
| tigera-operator | `tigera_operator_component_status{component,condition}` | TigeraStatus: `available`/`degraded`/`progressing` (**lowercase**) per component |
| | `tigera_operator_tls_certificate_expiry_timestamp_seconds{name}` | internal certificates (typha/node mTLS, webhooks, goldmane, whisker; CA 100 years) |
| | `controller_runtime_*`, `workqueue_*`, `rest_client_requests_total`, `leader_election_master_status`, `certwatcher_*` | controller-runtime |

**goldmane / whisker.** Goldmane logs `PrometheusPort:0`: its metrics endpoint is disabled (the `goldmane_*`
families seen under the other jobs are zero-valued registrations). Whisker exposes no metrics port. Enabling goldmane
metrics would need an operator-level override of the goldmane Deployment (Ansible, not this repo) — low value today.

**Dashboard `Calico dataplane`**: overview (Felix state, dataplane failures in range, iptables/ipset errors in range,
Typha → Felix streams, IP pool used, operator components degraded); Felix (dataplane apply time p50/p90/p99 =
policy programming latency, calc graph p99, applies/min vs failures, subprocess errors, iptables rules & ipsets,
active endpoints/policies/selectors, error logs & resyncs, route table resync p99, calico-node memory/CPU); Typha
(streams by syncer, client fall-behind & ping p99, connections accepted/dropped); IPAM (allocations vs pool, blocks &
borrowed, leaked candidates); tigera-operator (component status matrix, reconcile errors by controller, internal
certificates days left). Sources: [Felix](https://docs.tigera.io/calico/latest/reference/felix/prometheus),
[Typha](https://docs.tigera.io/calico/latest/reference/typha/prometheus),
[kube-controllers](https://docs.tigera.io/calico/latest/reference/kube-controllers/prometheus) metric references,
the official dashboards below, [controller-runtime metrics](https://book.kubebuilder.io/reference/metrics-reference);
thresholds from `monitoring-raw/calico.rules.yaml` (IP pool 90 %, Felix state ≠ 3, any restore error; dataplane
failures yellow from the first one). Operator certificate days-left colours (red < 30 d, yellow < 60 d) are a lab
choice: the operator renews them long before. EMPTY: none.

**Official dashboards** — from [projectcalico/calico v3.33.0 manifests/grafana-dashboards.yaml](https://github.com/projectcalico/calico/blob/v3.33.0/manifests/grafana-dashboards.yaml)
(the release ships Felix and Typha; there is no kube-controllers dashboard):

- *Calico Felix*: `job="calico-felix"` added to every selector (upstream queries have no job filter and would also
  match the zero-valued copies); eBPF *Events/s* and *Lost events* removed (`felix_bpf_events` never exists with the
  iptables dataplane); eBPF conntrack and nftables-era panels kept (they show 0). EMPTY: *Felix restarts/hr* and
  *Felix datastore resyncs/hr* (they filter `> 0`: no restart/resync in the window).
- *Calico Typha*: `job="calico-typha"` everywhere (upstream used `job="typha_metrics"` or none), `[30s]` rate windows
  → `$__rate_interval` (with a 30 s scrape a 30 s window has < 2 samples), descriptions added to 8 panels. EMPTY: none.

**Alert fix.** `TigeraOperatorComponentDegraded` matched `condition="Degraded"`, but the operator exports
`condition="degraded"` (lowercase): the alert could never fire. Fixed in `monitoring-raw/calico.rules.yaml`.

---

## MetalLB (L2)

**What it does here.** helm-charts/metallb, v0.16.2, L2 only (no FRR): IPAddressPool `lan` 192.168.68.240-245
(6 addresses) + L2Advertisement. In use: `gateway/public-istio` .240, `gateway/mcp-istio` .241.

**Scrape.** Chart ServiceMonitors: job `metallb` (speaker, hostNetwork :9120 https) and job
`metallb-controller-monitor-service` (controller). Chart PrometheusRule `metallb.rules` (stale config, config not
loaded, pool exhausted, 75/85/95 % usage, BGP down — unused in L2).

| Metric | Exported by | Meaning |
|--------|-------------|---------|
| `metallb_allocator_addresses_in_use_total`, `metallb_allocator_addresses_total` (+ `_ipv4_`/`_ipv6_` variants) | controller | pool usage per pool |
| `metallb_speaker_announced{ip,node,protocol}` | speaker | IPs the node announces |
| `metallb_layer2_requests_received`, `metallb_layer2_responses_sent`, `metallb_layer2_gratuitous_sent` (per `ip`) | speaker | ARP traffic |
| `metallb_k8s_client_config_loaded_bool`, `metallb_k8s_client_config_stale_bool`, `metallb_k8s_client_updates_total`, `metallb_k8s_client_update_errors_total` | both | config state |
| `controller_runtime_*`, `workqueue_*`, `rest_client_*`, `go_*`, `process_*` | both | runtime |

No official dashboard exists (the MetalLB docs list metrics and sample alerts only:
[metallb.io/prometheus-metrics](https://metallb.io/prometheus-metrics/)); community references: grafana.com
[20162](https://grafana.com/grafana/dashboards/20162) (r6) and 14127. 20162's L2 and client panels are reused (same
expressions, lab labels).

---

## external-dns (Cloudflare)

**What it does here.** helm-charts/external-dns, v0.23.0 (chart 1.23.0): source `gateway-httproute`, provider
Cloudflare (token from Vault `homelab/cloudflare`), policy `sync`, registry TXT (`_extdns.` prefix, owner `k8s01`),
interval 1 m. Today: 11 `a` records wanted by sources and verified; the registry reports 13 `a` and 12 `cname` records
(`external_dns_registry_records`).

**Scrape.** Chart ServiceMonitor, job `external-dns` (:7979), ~90 series.

| Metric | Meaning |
|--------|---------|
| `external_dns_controller_last_sync_timestamp_seconds` / `_last_reconcile_timestamp_seconds` | last successful / attempted sync with the provider |
| `external_dns_controller_consecutive_soft_errors` | consecutive failed loops (retryable errors) |
| `external_dns_controller_no_op_runs_total` | loops with nothing to change |
| `external_dns_controller_verified_records{record_type}` | records in both source and registry |
| `external_dns_source_endpoints_total`, `external_dns_source_records{record_type}`, `external_dns_source_errors_total` | what HTTPRoutes ask for |
| `external_dns_registry_endpoints_total`, `external_dns_registry_records{record_type}`, `external_dns_registry_errors_total` | what is in Cloudflare (incl. TXT ownership) |
| `external_dns_source_invalid_endpoints`, `external_dns_source_deduplicated_endpoints`, `external_dns_registry_skipped_records_owner_mismatch_per_sync` | rejected/skipped endpoints — vectors, only exported once non-zero |
| `external_dns_http_request_duration_seconds` | **Kubernetes API** calls only (gateways, httproutes, namespaces); the Cloudflare provider is not instrumented |
| `external_dns_provider_cache_apply_changes_calls`, `external_dns_webhook_provider_*` | provider cache / webhook provider: unused here (0) |

Reference: [external-dns v0.23.0 metrics](https://kubernetes-sigs.github.io/external-dns/v0.23.0/docs/monitoring/metrics/).
Community dashboard grafana.com [15038](https://grafana.com/grafana/dashboards/15038) (r3) was reviewed but not
imported: it uses the removed per-type metric names (`external_dns_registry_a_records`, …), so half of it is empty
with v0.23; its panel ideas (endpoints, sync timestamps, records, errors) are reproduced with current names.

**Dashboard `MetalLB & external-dns`**: overview (pool usage gauge, addresses in use/total, IPs announced, MetalLB
config, external-dns seconds since last successful sync, consecutive soft errors); MetalLB (LoadBalancer Services and
IPs with announced flag, pool usage over time, ARP requests/responses per IP, gratuitous ARP, k8s updates & errors,
config loaded/stale); external-dns (endpoints source vs registry, records by type source/registry/verified, errors,
sync freshness, no-op loops, rejected/skipped endpoints). Thresholds: pool 75/85/95 % from the chart's rules; sync
age yellow > 120 s / red > 300 s is **derived** from the configured 1 m interval (2 and 5 missed loops), not an
upstream value. EMPTY: *Rejected / skipped endpoints* (nothing rejected; the gauges only appear when non-zero).

---

## Gaps and recommendations

- **Pending after sync** (owner commit + push): istio-cni PodMonitor (job `istio-system/istio-cni`); Envoy stats
  matcher (then restart `gateway/public-istio` and `gateway/mcp-istio`). Check: `up{job="istio-system/istio-cni"}`,
  `envoy_cluster_membership_healthy{job="istio-system/gateway-envoy"}`, `envoy_listener_ssl_handshake`.
- **Alerts worth adding** (none exist for Istio/gateways/external-dns): gateway 5xx ratio per backend > 5 % for 10 m
  (mirrors the Istio success-rate red threshold); gateway pod `up == 0`; `envoy_cluster_membership_healthy == 0` for
  a routed backend (once scraped); `pilot_xds` < 3 or `increase(pilot_total_xds_rejects[10m]) > 0`; external-dns
  `time() - external_dns_controller_last_sync_timestamp_seconds > 600` and `consecutive_soft_errors > 3`;
  `metallb_speaker_announced` count lower than LoadBalancer Services with an IP. They would live in
  istio-raw / gateway-raw / external-dns-raw; thresholds need the owner's call, so they are not added yet.
- **Cardinality option:** istiod env `PILOT_FILTER_GATEWAY_CLUSTER_CONFIG=true` would send gateways only the clusters
  their routes reference (~15 instead of ~148), cutting the new Envoy series ~10× and gateway memory. Behaviour change
  of istiod: left for the owner.
- **Gateway labels:** the `gateway-envoy` PodMonitor could copy the pod label `gateway.networking.k8s.io/gateway-name`
  (`podTargetLabels`) so Envoy series carry the Gateway name instead of matching on pod-name prefixes.
- **Ztunnel/mesh:** nothing to enable until a namespace joins ambient; then the ztunnel panels, the official Ztunnel
  dashboard and the Mesh *TCP Workloads* table fill automatically.
- **Calico (Ansible):** goldmane metrics are disabled (`PrometheusPort:0`); enabling them needs an operator override
  in homelab-ansible. Felix logs ~47 error lines since start with 5 dataplane failures in 6 h (transient, alert did
  not fire); worth a look in `calico-node` logs if the dataplane failure counter keeps moving.
- **CoreDNS** is covered by the Kubernetes group, not duplicated here.
