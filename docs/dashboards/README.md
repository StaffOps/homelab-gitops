# Grafana dashboards

Every dashboard of the lab, by Grafana folder. Each one has a "How to read" panel at the top, a description on
every panel (what it shows, what normal and bad look like, where the formula comes from) and annotations for firing
alerts and container restarts. Details per service — exported metrics, panel formulas and their sources, panels that
are expected to be empty, gaps — are in the group files linked below.

## How dashboards are shipped

- One JSON file per dashboard in `helm-charts/monitoring/monitoring-raw/dashboards/<folder>/<name>.json`;
  monitoring-raw turns each file into a ConfigMap `dashboard-<folder>-<name>` (label `grafana_dashboard: "1"`,
  annotation `grafana_folder`), and the Grafana sidecar files it under that folder. Add a dashboard = add a file.
- kube-prometheus-stack's own dashboards (kubernetes-mixin, node-exporter, etcd, CoreDNS, Prometheus, Alertmanager,
  Grafana overview) land in folder "Kubernetes" (`grafana.sidecar.dashboards.annotations`).
- UIDs are `hl-<folder>-<name>`. "(official)" / "/ Official" dashboards are upstream ones, pinned to the installed
  version and adapted to this lab's labels (source and revision in their description); the others are curated.
- Check every query against the live Prometheus before pushing:
  `scripts/check-dashboard.py helm-charts/monitoring/monitoring-raw/dashboards/*/*.json` (needs a port-forward to
  `svc/kps-prometheus` on 19090). 0 errors is required; EMPTY results must be explained in the group file.

## Kubernetes — [kubernetes.md](kubernetes.md)

| Dashboard | Kind | UID | File |
|-----------|------|-----|------|
| Cluster add-ons | curated | `hl-kubernetes-addons` | `kubernetes/addons.json` |
| Cluster health: node & capacity | curated | `hl-kubernetes-cluster-health` | `kubernetes/cluster-health.json` |
| Control plane | curated | `hl-kubernetes-control-plane` | `kubernetes/control-plane.json` |
| kube-prometheus-stack (27 dashboards) | official | chart | `kube-prometheus-stack` |

## Networking & Ingress — [networking.md](networking.md)

| Dashboard | Kind | UID | File |
|-----------|------|-----|------|
| Calico Felix (official) | official | `hl-networking-calico-felix` | `networking/calico-felix.json` |
| Calico Typha (official) | official | `hl-networking-calico-typha` | `networking/calico-typha.json` |
| Calico dataplane | curated | `hl-networking-calico` | `networking/calico.json` |
| Ingress / Gateway | curated | `hl-networking-gateway` | `networking/gateway.json` |
| Istio Control Plane (official) | official | `hl-networking-istio-control-plane` | `networking/istio-control-plane.json` |
| Istio Mesh (official) | official | `hl-networking-istio-mesh` | `networking/istio-mesh.json` |
| Istio Ztunnel (official) | official | `hl-networking-istio-ztunnel` | `networking/istio-ztunnel.json` |
| Mesh / istiod & ztunnel | curated | `hl-networking-mesh` | `networking/mesh.json` |
| MetalLB & external-dns | curated | `hl-networking-metallb-external-dns` | `networking/metallb-external-dns.json` |

## Security & Identity — [security.md](security.md)

| Dashboard | Kind | UID | File |
|-----------|------|-----|------|
| cert-manager | curated | `hl-security-cert-manager` | `security/cert-manager.json` |
| Dependency-Track (official) | official | `hl-security-dependency-track-official` | `security/dependency-track-official.json` |
| Dependency-Track | curated | `hl-security-dependency-track` | `security/dependency-track.json` |
| External Secrets (official) | official | `hl-security-external-secrets-official` | `security/external-secrets-official.json` |
| External Secrets | curated | `hl-security-external-secrets` | `security/external-secrets.json` |
| Keycloak capacity planning (official) | official | `hl-security-keycloak-capacity` | `security/keycloak-capacity.json` |
| Keycloak troubleshooting (official) | official | `hl-security-keycloak-troubleshooting` | `security/keycloak-troubleshooting.json` |
| Keycloak | curated | `hl-security-keycloak` | `security/keycloak.json` |
| Kyverno (official) | official | `hl-security-kyverno-official` | `security/kyverno-official.json` |
| Kyverno | curated | `hl-security-kyverno` | `security/kyverno.json` |
| Vault | curated | `hl-security-vault` | `security/vault.json` |

## Observability — [observability.md](observability.md)

| Dashboard | Kind | UID | File |
|-----------|------|-----|------|
| Alertmanager | curated | `hl-observability-alertmanager` | `observability/alertmanager.json` |
| Grafana | curated | `hl-observability-grafana` | `observability/grafana.json` |
| Loki | curated | `hl-observability-loki` | `observability/loki.json` |
| OpenTelemetry Collectors | curated | `hl-observability-otel-collectors` | `observability/otel-collectors.json` |
| OpenTelemetry Operator & OBI | curated | `hl-observability-otel-operator` | `observability/otel-operator.json` |
| Prometheus Operator | curated | `hl-observability-prometheus-operator` | `observability/prometheus-operator.json` |
| Prometheus | curated | `hl-observability-prometheus` | `observability/prometheus.json` |
| Tempo | curated | `hl-observability-tempo` | `observability/tempo.json` |

## GitOps & Platform — [platform.md](platform.md)

| Dashboard | Kind | UID | File |
|-----------|------|-----|------|
| Argo CD / Operations | curated | `hl-platform-argocd-ops` | `platform/argocd-ops.json` |
| Argo CD / Official | official | `hl-platform-argocd` | `platform/argocd.json` |
| KEDA / Operations | curated | `hl-platform-keda-ops` | `platform/keda-ops.json` |
| KEDA / Official | official | `hl-platform-keda` | `platform/keda.json` |
| Velero / Backups | curated | `hl-platform-velero-ops` | `platform/velero-ops.json` |
| Velero / Official | official | `hl-platform-velero` | `platform/velero.json` |

## Databases — [databases.md](databases.md)

| Dashboard | Kind | UID | File |
|-----------|------|-----|------|
| CloudNativePG / Official | official | `hl-data-cnpg` | `data/cnpg.json` |
| PostgreSQL / Clusters | curated | `hl-data-postgresql` | `data/postgresql.json` |

## AI & GPU — [ai.md](ai.md)

| Dashboard | Kind | UID | File |
|-----------|------|-----|------|
| GPU (GeForce GT 740) | curated | `hl-ai-gpu` | `ai/gpu.json` |
| LLM (llama.cpp) | curated | `hl-ai-llm` | `ai/llm.json` |
| MCP servers | curated | `hl-ai-mcp-servers` | `ai/mcp-servers.json` |
