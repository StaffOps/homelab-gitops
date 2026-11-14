# Architecture

One kubeadm node (`k8s01`, Kubernetes v1.37, Calico, 8 CPU / 32 GB / 220 GB SSD, GeForce GT 740) on the home LAN `192.168.68.0/24`.
Argo CD reconciles everything from `main`; the operator only bootstraps, unseals Vault and writes secrets.

## App catalog

| App (`helm-charts/…`) | Namespace | What | Depends on |
|-----------------------|-----------|------|------------|
| `argo` | argo | Argo CD (self-managed) + ApplicationSet `platform` | prometheus-operator CRDs (bootstrap) |
| `local-path-provisioner` | local-path-storage | default StorageClass `local-path` (node disk) | — |
| `metrics-server` | kube-system | resource metrics API (`kubectl top`, HPA) | kubelet-csr-approver |
| `kubelet-csr-approver` | kube-system | approves kubelet serving-certificate renewals | — |
| `metallb` | metallb-system | LoadBalancer IPs from `192.168.68.240-245` (L2) | — |
| `vault` | vault | secret store (standalone, file storage, manual unseal) | — |
| `external-secrets` | external-secrets | `ClusterSecretStore vault` (Kubernetes auth) | vault (configured) |
| `cert-manager` | cert-manager | Let's Encrypt issuers, DNS-01 on Cloudflare | external-secrets |
| `external-dns` | external-dns | Cloudflare records for HTTPRoutes | external-secrets, gateway |
| `istio` | istio-system | Istio ambient (istiod, CNI, ztunnel), GatewayClass `istio` | Gateway API CRDs (bootstrap) |
| `gateway` | gateway | Gateway `public` on `192.168.68.240` + wildcard certificate | istio, metallb, cert-manager |
| `monitoring` | monitoring | kube-prometheus-stack, short names `kps-*` (Prometheus with OTLP receiver, Alertmanager, Grafana), Loki 3.7, Tempo 3.1 | prometheus-operator CRDs |
| `opentelemetry` | opentelemetry | OpenTelemetry Operator, collectors otel-agent / otel-logs / otel-gateway, OBI (eBPF) | cert-manager |
| `cloudnative-pg` | cnpg-system | PostgreSQL operator (`Cluster` resources) | — |
| `keycloak` | keycloak | identity provider (OIDC/SAML), PostgreSQL `keycloak-db` (CloudNativePG) | cloudnative-pg, external-secrets |
| `keda` | keda | event-driven autoscaling (ScaledObject, ScaledJob) | — |
| `dependency-track` | dependency-track | SBOM analysis (API server + frontend), PostgreSQL `dtrack-db` | cloudnative-pg, external-secrets |
| `velero` | velero | daily backup of stateful namespaces (objects + volumes) to Cloudflare R2 | external-secrets |
| `kyverno` | kyverno | policy engine; Pod Security Standards baseline in Audit (PolicyReports); label `topology.kubernetes.io/zone=k8s-local` on every new Pod | — |
| `nvidia-device-plugin` | nvidia-device-plugin | RuntimeClass `nvidia` + device plugin → `nvidia.com/gpu: 1` (GT 740, driver 470 on the host) | GPU setup in Ansible |
| `mcp-servers` | mcp-servers | MCP servers at `mcp.staffops.space/<name>`: kubernetes, grafana, argocd, dependency-track, keycloak (+ tempo built-in), read-only, Keycloak JWT at the Gateway | keycloak, external-secrets |
| `llm` | llm | llama.cpp server (Vulkan, GT 740) at `llm.staffops.space`, OpenAI-compatible, API key from Vault | nvidia-device-plugin |

kubeadm provides the control plane, CoreDNS and kube-proxy; Ansible (`homelab-ansible`) installs Calico. No
StorageClass, metrics API, LoadBalancer, ingress or Gateway API CRDs come with it (ADR 0006).

## Traffic

```
LAN client ──DNS──► Cloudflare: <app>.staffops.space A 192.168.68.240   (external-dns, not proxied)
          ──HTTPS─► 192.168.68.240:443  MetalLB (L2) → Service of Gateway "public" (Istio)
                    TLS terminated with *.staffops.space (cert-manager, Let's Encrypt DNS-01)
                    → HTTPRoute <app> → Service of the app
http :80 → 301 to https (HTTPRoute https-redirect)
```

Records are public but point to a private address: the services are reachable only from the LAN (or a VPN
into it). DNS-01 needs no inbound connectivity.

## Telemetry

```
apps (SDK) / OBI ──OTLP──► otel-agent (DaemonSet, node-local Service) ──OTLP──► otel-gateway (Deployment)
VPS ──OTLP/HTTP, Bearer token── https://otel.staffops.space ──────────────────────►┘
otel-gateway: span metrics + service graph ─► Prometheus (/api/v1/otlp) · traces ─► Tempo · logs ─► Loki
/var/log/pods + Kubernetes events ──► otel-logs (DaemonSet, events via leader election) ──► Loki (/otlp)
```

- Apps send OTLP to `otel-agent-collector.opentelemetry:4317` (gRPC) or `:4318` (HTTP).
- OBI instruments only the namespaces in `helm-charts/opentelemetry/obi/values.yaml.gotmpl` (rule
  `instrumented-namespaces`, today `staffops*`) and skips processes that already export OTLP.
- Grafana: Loki and Tempo datasources linked both ways (trace → logs, log `trace_id` → trace).

## Secrets

```
operator ──scripts/vault.sh put──► Vault secret/homelab/<name>  (KV v2)
External Secrets ──Kubernetes auth (role external-secrets)──► reads secret/homelab/*
ExternalSecret in the app namespace ──► Kubernetes Secret used by the chart
```

Vault starts **sealed** after every restart of `vault-0` (node reboot included). While sealed, existing
Kubernetes Secrets keep working but nothing refreshes; alert `VaultSealed` fires. Unseal with
`scripts/vault.sh unseal`. The unseal key and root token live outside the repository
(`~/.config/homelab/vault-init.json` + an offline copy).

| Vault key | Keys | Used by |
|-----------|------|---------|
| `homelab/cloudflare` | `api-token` | cert-manager, external-dns |
| `homelab/grafana` | `admin-user`, `admin-password` | monitoring (Grafana) |
| `homelab/keycloak` | `admin-user`, `admin-password` | keycloak (bootstrap admin) |
| `homelab/otel` | `external-token` | otel-gateway external receiver (VPS) |
| `homelab/oidc` | `argocd`, `grafana`, `vault` | Keycloak client secrets (keycloak, argo, monitoring) |
| `homelab/dependency-track` | `kek` | dependency-track (encryption key of stored secrets) |
| `homelab/velero` | `access-key-id`, `secret-access-key`, `endpoint` | velero (R2 API token + S3 endpoint) |

## GitOps flow

`bootstrap.sh apply` installs the prerequisite CRDs, the `argo-cd` release and the root Application
`argo-cd`. From then on Argo CD syncs `helm-charts/argo` (itself + `argo-cd-raw`), and the ApplicationSet
`platform` creates one Application per listed app, each rendered by the helmfile plugin
(`helmfile template --include-crds`). Ordering between apps comes from retries and
`SkipDryRunOnMissingResource`: an app whose CRDs are not there yet retries until they are.

Exposed hostnames: `argocd`, `vault`, `grafana`, `prometheus`, `alertmanager`, `keycloak`, `dependency-track`, `otel` (OTLP/HTTP for external clusters), `llm`, `mcp`
(`.staffops.space`).
