# Dashboards: AI & GPU

Grafana folder **AI & GPU**, files in `helm-charts/monitoring/monitoring-raw/dashboards/ai/` (one ConfigMap
`dashboard-ai-<name>` each, rendered by `monitoring-raw`).

| Dashboard | uid | File | Kind |
|-----------|-----|------|------|
| LLM (llama.cpp) | `hl-ai-llm` | `ai/llm.json` | curated (no official dashboard exists) |
| GPU (GeForce GT 740) | `hl-ai-gpu` | `ai/gpu.json` | curated from the official exporter dashboard 14574 r18 |
| MCP servers | `hl-ai-mcp-servers` | `ai/mcp-servers.json` | curated (no official dashboard exists) |

Every dashboard has a "How to read this dashboard" text panel, a description on every panel (with the formula
source) and these annotations: firing alerts of the namespace, container restarts, plus a service event (llama pod
start = model load; GPU holder (re)scheduled; MCP Deployment rollouts via `kube_deployment_status_observed_generation`).

Validated with `scripts/check-dashboard.py` against the live Prometheus: **0 errors** on all three files. The
EMPTY results are listed per dashboard below.

---

## llama.cpp server (`llm`)

**What it does here.** Deployment `llama` (namespace `llm`) runs `ghcr.io/ggml-org/llama.cpp:server-vulkan` (build
b12359) with the Vulkan backend on the GT 740: Qwen2.5-1.5B-Instruct Q4_K_M, `-c 4096`, all layers offloaded
(~1.2 GiB VRAM). OpenAI-compatible API at `https://llm.staffops.space` (Gateway `public`), API key from Vault
`homelab/llm`; measured ~21 tok/s prompt, ~7.5 tok/s generation.

**Scrape.** ServiceMonitor `llama` (llm-raw), job `llama`, 15 s, `/metrics` with the API key as bearer token
(`--metrics`). 15 `llamacpp:*` series. Reference: [llama.cpp server README – /metrics](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md#get-metrics-prometheus-compatible-metrics-exporter);
HELP texts read from the Prometheus metadata API.

| Metric | Type | Meaning / use |
|--------|------|---------------|
| `llamacpp:tokens_predicted_total` | counter | generated tokens → generation throughput |
| `llamacpp:tokens_predicted_seconds_total` | counter | time spent generating → speed while working, busy ratio |
| `llamacpp:prompt_tokens_total` | counter | prompt tokens evaluated (**excludes cached**) |
| `llamacpp:prompt_seconds_total` | counter | time spent evaluating prompts |
| `llamacpp:prompt_tokens_cached_total` | counter | prompt tokens reused from the KV cache (not in the README table; HELP text) |
| `llamacpp:predicted_tokens_seconds`, `prompt_tokens_seconds` | gauge | average speed **over the window between two scrapes**; reset at every scrape, 0 when no request finished in that window ([server-context.cpp](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/server-context.cpp): "the gauges are averaged over the window between two scrapes") |
| `llamacpp:requests_processing` | gauge | requests in a slot |
| `llamacpp:requests_deferred` | gauge | requests waiting for a free slot (queue) |
| `llamacpp:n_tokens_max` | counter | largest prompt+generation length seen by a slot since start (compare with `-c 4096`) |
| `llamacpp:n_decode_total` | counter | `llama_decode()` calls |
| `llamacpp:n_busy_slots_per_decode` | gauge | cumulative average since start (busy slots / decodes): not used, it barely moves |
| `llamacpp:spec_decode_*` | counter | speculative decoding: always 0 (no draft model), not used |

`kv_cache_usage_ratio` / `kv_cache_tokens` from older README versions **do not exist** in this build. llama.cpp
exports no request counter, no error counter and no latency histogram: requests/status/latency come from the
Envoy of Gateway `public` (`istio_requests_total`, `istio_request_duration_milliseconds_bucket`, reporter=source,
`destination_service_name="llama"`).

**Dashboard `LLM (llama.cpp)`** — replaces the ConfigMap `llm-dashboard` (General folder, uid `llm-llamacpp`)
that lived in `helm-charts/llm/llm-raw/resources/dashboard.yaml` (deleted; Argo CD prunes it). Old links to
`/d/llm-llamacpp` stop working.

- Overview: Up (`up`), Ready replicas (kube-state-metrics), Requests processing / deferred, Generation speed and
  Prompt speed over the range (`increase(tokens)/increase(seconds)` — derived from the documented counter
  semantics), Longest sequence (`n_tokens_max`, red at the 4096 hard limit), Prompt cache reuse
  (`cached / (cached + evaluated)`, per the HELP texts).
- Throughput: tokens/s (generated, evaluated, from cache); speed while working (`rate(tokens)/rate(seconds)` plus
  the server gauges as points, zeros hidden); busy time per second (`rate(*_seconds_total)`, the GPU activity proxy
  because nvidia-smi has no utilization for this GPU); concurrency and queue.
- API traffic at the Gateway: requests/s by status code, p50/p95 duration (formulas of the Istio Service dashboard).
- Resources: CPU vs request and working set vs limit (kubernetes-mixin `k8s-resources-pod` formulas), VRAM used vs
  total (exporter), restarts, decode calls/s.

**EMPTY panels (expected):**
- *Speed while working* [C, D] — the server gauges filtered `> 0`: empty while no request finished in the last
  scrape window (idle).
- *Requests per second by status code*, *Request duration* — the Gateway creates `istio_requests_total` series for
  `llama` only after the first API request since the `public-istio` pod started; empty = no API traffic.
- Rates read 0 and range speeds read NaN when the model was not used in the window.

**Not available / not shown.** Model PVC usage: `kubelet_volume_stats_*` for `models` reports the whole node
filesystem (local-path is a hostPath), so it is not shown (node disk is on the Kubernetes dashboards).

---

## NVIDIA GPU (`nvidia-device-plugin` app)

**What it does here.** One GeForce GT 740 (Kepler, CC 3.0, 4 GiB), host driver 470.256.02 (CUDA 11.4), installed by
the Ansible role `gpu`. RuntimeClass `nvidia`; the **NVIDIA k8s-device-plugin 0.20.1** advertises `nvidia.com/gpu: 1`
(exclusive, today `llm/llama`). **nvidia-gpu-exporter 1.18.0** (chart 2.18.0) runs the host's `nvidia-smi` (exec
backend, `--query-field-names AUTO`) without requesting the GPU.

**Scrape.** ServiceMonitor from the exporter chart, job `nvidia-gpu-exporter`, 30 s, `instance="k8s01"`. The device
plugin **exports no metrics** (no metrics port or option in chart 0.20.1); its health comes from kube-state-metrics
(`kube_node_status_allocatable{resource="nvidia_com_gpu"}`, DaemonSet status).

| Family | Metrics | Use |
|--------|---------|-----|
| Collection health | `nvidia_smi_last_collect_success`, `_last_collect_success_timestamp_seconds`, `_last_collect_duration_seconds`, `_failed_scrapes_total`, `_command_exit_code` | is the GPU data fresh; chart alerts Collection Failing / Stale (>300 s) / Slow (>5 s) |
| Thermal | `nvidia_smi_temperature_gpu`, `nvidia_smi_fan_speed_ratio` | overheating, fan |
| Memory | `nvidia_smi_memory_used_bytes`, `_free_bytes`, `_total_bytes` | VRAM headroom for models / context |
| State | `nvidia_smi_pstate` (P0 busy … P8 idle), `_compute_mode`, `_persistence_mode` | activity; configuration |
| Identity | `nvidia_smi_gpu_info` (labels: name, driver, CUDA, VBIOS, compute_cap, PCI), `_name`, `_index`, `_count`, `_pci_*`, `nvidia_gpu_exporter_build_info` | what is installed |
| Throttle | `nvidia_smi_clocks_throttle_reasons_supported` = 0 | the card reports no throttle reasons |

**Missing on this card:** utilization (GPU/memory/encoder/decoder), power draw/limits, clocks, throttle reasons,
ECC, retired pages, XID, per-process memory. With `AUTO`, the exporter drops fields that nvidia-smi answers with
*N/A / Not Supported* — expected for a low-end Kepler GeForce on driver 470. Consequently most chart alerts
(thermal slowdown, power brake, ECC, XID, row remap, PCIe, compute apps) can never fire here; only the collection
alerts are meaningful.

**Official dashboard evaluated, not imported.** grafana.com [14574 "Nvidia GPU Metrics"](https://grafana.com/grafana/dashboards/14574)
revision 18 (maintainer utkuozdemir; the same JSON ships in the chart as `dashboards/nvidia-gpu-metrics.json`,
plus `nvidia-gpu-overview.json`, behind `grafanaDashboard.enabled`, default false — left off). Of its 49 panels only
~10 have data on this GPU (P-state, GPU info, compute mode, fan, temperature, memory); the rest (utilization,
power, clocks, throttle, NVENC/NVDEC, processes, ECC, XID, MIG, PCIe, energy) are permanently empty, so it has no
reference value here. Its usable panels — queries, thresholds and P-state mappings — are reproduced in the curated
dashboard.

**Dashboard `GPU (GeForce GT 740)`**
- Overview: Collection OK, Last good collection (red > 300 s = chart alert), Temperature (yellow 70 / red 80 °C,
  from 14574), VRAM used % (85 % / 95 %, from 14574), Fan, P-State (14574 mappings), GPUs allocatable, GPUs
  allocated; tables *Who holds the GPU* (`kube_pod_container_resource_requests{resource="nvidia_com_gpu"}` × pod
  phase) and *GPU identity* (14574 "GPU Info").
- History: VRAM used vs total, temperature (80 °C line), P-state timeline, fan, *GPU work (from llama.cpp)* (busy
  ratio of the only GPU user, since there is no utilization metric).
- Device plugin and exporter: DaemonSets ready (desired > 0 only; the MPS control daemon has 0 desired), exporter
  scrape `up`, failed collections, restarts, collection duration (5 s line = chart alert).

**EMPTY panels:** none.

---

## MCP servers (`mcp-servers`)

**What it does here.** Seven read-only MCP servers in namespace `mcp-servers`, reachable at
`https://mcp.staffops.space/<name>` through the dedicated Gateway `mcp` (192.168.68.241), which requires a Keycloak
JWT (groups `/mcp/admin`, `/mcp/viewer`) and rewrites the path to each server's endpoint. `/tempo` (Tempo's built-in
MCP, namespace monitoring) shares the Gateway.

| Server | Scrape | Own metrics |
|--------|--------|-------------|
| grafana-mcp (mcp-grafana 2.3.0) | ServiceMonitor (chart), job `grafana-mcp`, port 9090 | `mcp_server_operation_duration_seconds` (OTel MCP semconv: `mcp_method_name`, `gen_ai_tool_name`, `error_type` only on failures), `http_server_request_*` (incoming, `http_route=/mcp`), `http_client_request_*` (calls to Grafana), `mcp_client_cache_{hits,misses,lookups}_total`/`_size` (client cache per `client_type`, not shown), `target_info` — [docs](https://github.com/grafana/mcp-grafana/blob/main/docs/sources/developer/observability-metrics-and-tracing.md) |
| kubernetes-mcp (v0.1.3) | PodMonitor, job `mcp-servers/kubernetes-mcp` | `k8s_mcp_tool_calls_total`, `k8s_mcp_tool_errors_total` (created on first error), `k8s_mcp_tool_duration_seconds`, `k8s_mcp_http_requests_total` (`url_path`, status class), `k8s_mcp_requests_in_flight`, `k8s_mcp_server_info` — [docs](https://github.com/containers/kubernetes-mcp-server/blob/main/docs/OTEL.md) |
| prometheus-mcp (v0.18.0) | PodMonitor, job `mcp-servers/prometheus-mcp` | `prom_mcp_tool_call_duration_seconds`, `prom_mcp_tool_calls_failed_total`, `prom_mcp_api_call_duration_seconds`, `prom_mcp_api_calls_failed_total`, `prom_mcp_server_ready`, `prom_mcp_build_info`, `prom_mcp_docs_*` (embedded docs refresh, not shown), Go runtime — [docs](https://github.com/tjhop/prometheus-mcp-server#metrics) |
| argocd-mcp, dependency-track-mcp, keycloak-mcp | — | no metrics endpoint (404) |
| kubectl-mcp | — | serves a stub (`prometheus_client` missing in the image) |

All seven (+ tempo) appear in the **Gateway** metrics: the Envoy of `mcp-istio-*` (job `istio-system/gateway-envoy`,
namespace `gateway`) exports Istio standard metrics with `destination_service_name` = the backend Service, so each
path is one series: `istio_requests_total` (`response_code`, `response_flags`), `istio_request_duration_milliseconds`,
`istio_request_bytes`, `istio_response_bytes`. JWT rejections (401/403) are attributed to the routed server.
Pod health/resources for all seven come from kube-state-metrics and cAdvisor.

**Dashboard `MCP servers`**
- Overview: Deployments available (per server), Gateway requests/s, Gateway 5xx ratio (inverse of the Istio
  dashboards' success rate; yellow on any 5xx, red > 5 %), auth rejections (401/403), restarts.
- Per server at the Gateway: requests/s, non-2xx by server and code, p95 duration, table of requests per server and
  code over the range (Istio Service dashboard formulas). Note: a GET that opens an MCP event stream lasts until the
  client disconnects, so p95 can show long outliers.
- Pods and resources: CPU and working set by pod, working set / limit (80 % / 90 %), containers in a waiting state
  (kubernetes-mixin formulas and alert signals).
- kubernetes-mcp: tool calls/s, tool errors/s, p95 tool duration, HTTP requests by path and status class, in-flight
  by method.
- grafana-mcp: operations/s by method and tool, failed operations (`error_type!=""`), p95 tool duration, Grafana API
  calls by status, p95 incoming vs outgoing latency.
- prometheus-mcp: ready, tool calls and failures (tools and Prometheus API), p95 tool vs API duration.

Counters created on first use (errors, tool calls after a pod restart, in-flight gauge) use the fallback
`or on () (sum(up{job=...}) * 0)` so "nothing happened" shows 0 instead of No data — the same pattern the official
nvidia dashboard 14574 uses.

**EMPTY panels (expected):**
- *Containers not running (waiting reason)* — empty while every container runs (healthy state).
- *kubernetes-mcp p95 tool duration* — no tool call since the pod started (histogram series appear on the first call).

---

## Gaps and recommendations

- **Alerts worth adding (owner decision):**
  - `llm`: a PrometheusRule in `llm-raw` for `llamacpp:requests_deferred > 0` sustained (e.g. 10 min: demand above
    capacity) and for a generation speed collapse (`rate(tokens_predicted_total)/rate(tokens_predicted_seconds_total)`
    well below the ~7.5 tok/s baseline → CPU fallback). Scrape loss is already covered by `TargetDown`.
  - `mcp-servers`: 5xx ratio per `destination_service_name` at Gateway `mcp` (Istio metrics), since four servers
    export nothing themselves.
  - GPU: `kube_node_status_allocatable{resource="nvidia_com_gpu"} < 1` (device plugin lost the GPU) — no chart rule
    covers it.
- **GPU utilization.** Not obtainable with nvidia-smi on GT 740 + driver 470; the `-nvml` exporter image reads the same
  NVML data, so it is unlikely to help (not tested). The llama.cpp busy ratio is the proxy. To confirm the exact unsupported fields,
  run `nvidia-smi --query-gpu=utilization.gpu,power.draw,clocks.gr --format=csv` on the host (Ansible / operator).
- **llama.cpp request metrics for in-cluster callers** bypassing the Gateway are not visible (ambient ztunnel only
  gives TCP metrics). Fine today: all clients use `llm.staffops.space`.
- **kubectl-mcp** has no metrics until its image ships `prometheus_client`; argocd/dependency-track/keycloak MCP have
  no endpoint upstream. Gateway metrics cover them.
- The catalog `docs/dashboards/README.md` (referenced by `monitoring-raw/values.yaml.gotmpl`) should list these three
  dashboards.
