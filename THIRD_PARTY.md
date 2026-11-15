# Third-party content

Everything in this repository is under the [MIT-0](LICENSE) license **except** the files below, which are copied
(and adapted to this lab) from upstream projects and keep their original license. Each file also names its source in
its own description or header comment. All of them are Apache-2.0: keep that license with any copy
(https://www.apache.org/licenses/LICENSE-2.0).

## Grafana dashboards (`helm-charts/monitoring/monitoring-raw/dashboards/`)

| File | Source | License |
|------|--------|---------|
| `data/cnpg.json` | [cloudnative-pg/grafana-dashboards](https://github.com/cloudnative-pg/grafana-dashboards) @7dd1bc2 | Apache-2.0 |
| `networking/calico-felix.json`, `networking/calico-typha.json` | [projectcalico/calico](https://github.com/projectcalico/calico) v3.33.0, `manifests/grafana-dashboards.yaml` | Apache-2.0 |
| `networking/istio-control-plane.json`, `networking/istio-mesh.json`, `networking/istio-ztunnel.json` | [istio/istio](https://github.com/istio/istio) 1.30.8, `manifests/addons/dashboards/` | Apache-2.0 |
| `platform/argocd.json` | [argoproj/argo-cd](https://github.com/argoproj/argo-cd) v3.6.1, `examples/dashboard.json` | Apache-2.0 |
| `platform/keda.json` | [kedacore/keda](https://github.com/kedacore/keda) v2.21.0, `config/grafana/keda-dashboard.json` | Apache-2.0 |
| `platform/velero.json` | [grafana.com dashboard 16829](https://grafana.com/grafana/dashboards/16829) revision 5 (published for Velero) | no license stated on grafana.com |
| `security/dependency-track-official.json` | [DependencyTrack/dependency-track](https://github.com/DependencyTrack/dependency-track) 5.2.1, `dev/monitoring/grafana/dashboards/` | Apache-2.0 |
| `security/external-secrets-official.json` | [external-secrets/external-secrets](https://github.com/external-secrets/external-secrets) v2.15.0, `docs/snippets/dashboard.json` | Apache-2.0 |
| `security/keycloak-capacity.json`, `security/keycloak-troubleshooting.json` | [keycloak/keycloak-grafana-dashboard](https://github.com/keycloak/keycloak-grafana-dashboard) @f819507c13 | Apache-2.0 |
| `security/kyverno-official.json` | [kyverno/kyverno](https://github.com/kyverno/kyverno) Helm chart 3.10.0, `grafana/dashboard/kyverno-dashboard.json` in the chart | Apache-2.0 |

The other dashboards are written for this lab; their formulas follow the upstream monitoring mixins and docs cited in
each panel description (kubernetes-mixin, node-exporter-mixin, prometheus/alertmanager/grafana/loki/tempo mixins:
Apache-2.0).

## Alert rules copied from monitoring mixins

| File | Source | License |
|------|--------|---------|
| `helm-charts/monitoring/kube-prometheus-stack/coredns.rules.yaml` | [povilasv/coredns-mixin](https://github.com/povilasv/coredns-mixin) | Apache-2.0 |
| `helm-charts/monitoring/kube-prometheus-stack/prometheus-operator.rules.yaml` | [prometheus-operator/kube-prometheus](https://github.com/prometheus-operator/kube-prometheus) via kube-prometheus-stack 93.3.0 | Apache-2.0 |
| `helm-charts/monitoring/monitoring-raw/tempo.rules.yaml` | [grafana/tempo](https://github.com/grafana/tempo) `operations/tempo-mixin` v3.1.1 | Apache-2.0 (per the repo's LICENSING.md) |
| `helm-charts/monitoring/monitoring-raw/grafana.rules.yaml` | [grafana/grafana](https://github.com/grafana/grafana) `grafana-mixin` | Apache-2.0 (per the repo's LICENSING.md) |
| `helm-charts/vault/vault-raw/prometheus.rules.yaml` (mixin alerts) | [adinhodovic/vault-mixin](https://github.com/adinhodovic/vault-mixin) | Apache-2.0 |
| `helm-charts/cert-manager/cert-manager-raw/prometheus.rules.yaml` (mixin alerts) | [cert-manager-mixin](https://gitlab.com/uneeq-oss/cert-manager-mixin) | Apache-2.0 |
