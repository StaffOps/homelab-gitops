# AGENTS.md — homelab-gitops

Rules for AI agents and operators (Claude Code loads it through `CLAUDE.md`).

GitOps for a single-node kubeadm homelab (Kubernetes v1.37, Calico): node and kube context `k8s01` (192.168.68.104, Ubuntu 24.04). Argo CD
manages itself and every platform app from this repository (`main` on GitHub, public). Secrets live in Vault
inside the cluster; DNS and certificates use Cloudflare.

Read first: [docs/overview.md](docs/overview.md), [docs/architecture.md](docs/architecture.md),
[docs/gitops-workflow.md](docs/gitops-workflow.md), [docs/status.md](docs/status.md); then
[docs/adr/](docs/adr/README.md) and [docs/runbooks/](docs/runbooks/README.md) as needed.

## How changes reach the cluster

| What | How |
|------|-----|
| Argo CD itself (`helm-charts/argo/**`) | commit + push to `main` → Application `argo-cd` syncs it |
| Add / remove a platform app | element in `helm-charts/argo/argo-cd-raw/resources/applicationset-platform.yaml` → push |
| Add / remove a workload app | in the repo `StaffOps/homelab-gitops-apps` (ApplicationSet `apps`, ADR 0007); nothing here |
| An existing app (`helm-charts/<app>/`) | commit + push |
| Lab-wide values (domain, IPs, Vault paths) | `helm-charts/environment.yaml` → push (every app re-renders) |
| A secret value | `scripts/vault.sh put <name> <keys…>` — never in git |
| Prerequisite CRDs (Gateway API, prometheus-operator) | `./bootstrap.sh apply` |
| Host, kubeadm, Calico | Ansible repository `homelab-ansible` (see docs/runbooks/node.md) |
| First install / full recovery of Argo CD | `./bootstrap.sh apply` or `./bootstrap.sh apply --takeover` |
| Image bumps of our own images (`ghcr.io/staffops/**`, `personalaigent/**`, `staffops-mentoring/**`) | Renovate opens **and auto-merges** the PR (`renovate.json5`, owner decision 2026-11-19). These merges are authorized: do not treat them as a rule-2 violation or revert them. Rollback = revert **plus** a temporary pin in `renovate.json5` (see the comment on the automerge rule) |

## Hard rules

1. **Always target context `k8s01` explicitly** (`kubectl --context k8s01`, `helmfile` envs pin it). The
   operator's kubeconfig also holds unrelated clusters and the current context is often one of them. The
   scripts refuse to run unless the context has exactly the node `k8s01`.
2. **Never commit or push without the operator's explicit authorization.** Commit only the files of the
   change, by explicit path; Conventional Commits; no AI co-author lines.
3. **Never run Helm/helmfile `apply` for the `argo-cd` release on a running cluster.** Argo CD owns those
   objects through server-side apply; `bootstrap.sh` refuses unless `--takeover` (recovery only).
4. **Render before every push**: `scripts/render-app.sh <app>` (or `--all`). It also checks the YAML embedded
   in `argocd-cm`: a broken `resource.exclusions` crash-loops the controller and Argo CD cannot sync the fix.
5. **What is on `main` is what runs** (`selfHeal`). Directories not listed in the ApplicationSet are drafts.
6. **No secrets in git.** Credentials come from Vault through External Secrets (`ClusterSecretStore vault`,
   key `homelab/<name>`). Literal `Secret` data in a render is a finding.
7. **4-space indentation** in YAML/gotmpl and bash. **Pinned versions** of charts and images, never `latest`.
8. Nothing from employers or other organizations in this repository (names, domains, accounts, internal
   links): it is a personal lab.

## Conventions for a platform app

- **Layout**: `helm-charts/<app>/helmfile.yaml.gotmpl` loads `../environment.yaml`, declares each release with
  `enabled` + `version` in the environment values and `condition: <release>.enabled`; each release has a
  `<release>/values.yaml.gotmpl`. Extra objects go in a `<app>-raw` release (bedag/raw), one file per object
  in `<app>-raw/resources/` when there are several.
- **Exposure**: an HTTPRoute with `parentRefs: [{name: public, namespace: gateway, sectionName: https}]` and
  hostname `<app>.{{ .Values.domain }}`. external-dns creates the Cloudflare record, the Gateway's wildcard
  certificate covers TLS. Never an Ingress, never a LoadBalancer Service per app.
- **Namespace**: add it to `platform.namespaces` in `helm-charts/environment.yaml` (ClusterSecretStore allow list and
  AppProject `apps` deny list) and to the ApplicationSet `platform`.
- **Secrets**: an ExternalSecret to `ClusterSecretStore vault`, `remoteRef.key: {{ .Values.vault.prefix }}/<name>`;
  add the key to docs/runbooks/vault.md. Values a chart would generate randomly (`randAlphaNum`, `genCA`, `lookup`)
  must come from an existing Secret, or every Argo CD render differs: render twice and diff.
- **Mesh**: every namespace is Istio ambient (Kyverno). A NetworkPolicy must allow TCP 15008 and
  `169.254.7.127/32` (see `argo-cd-raw/resources/networkpolicy-ambient.yaml`).
- **Database**: a CloudNativePG `Cluster` in the `-raw` release with the Barman Cloud ObjectStore and ScheduledBackup
  (copy `helm-charts/harbor/harbor-raw/resources/database.yaml`, including the `backup.postgres` restore switch).
- **Observability**: enable the chart's ServiceMonitor/PodMonitor (Prometheus selects every namespace), ship a
  PrometheusRule from upstream sources, and a dashboard in `monitoring-raw/dashboards/<folder>/`
  ([docs/dashboards/README.md](docs/dashboards/README.md)).
- **Storage**: StorageClass `local-path` from `helm-charts/local-path-provisioner` (single node: data lives on
  the node's disk, no replication).
- **Single node**: 1 replica, no PodDisruptionBudgets (they only block drains). Exception: components whose outage
  blocks the cluster (fail-closed webhooks, aggregated APIs, DNS, gateways) run 2 replicas
  ([docs/architecture.md](docs/architecture.md#9-resilience-on-a-single-node)).

## Templating gotchas

- `helm-charts/argo` has two releases: `argo-cd` (chart + CRDs) and `argo-cd-raw` (AppProject, root
  Application, ApplicationSet; needs the CRDs). bedag/raw does not run `tpl`, so Argo CD expressions are
  escaped once: ``'{{`{{ .appName }}`}}'``. bootstrap.sh installs only `argo-cd` plus the seed.
- Never put Argo CD CRD kinds in `extraObjects` of the argo-cd chart: the first install fails.
- `prometheus.rules.yaml` files are inserted with `readFile` (no `tpl`): write Prometheus templates plainly
  (`{{ $labels.name }}`), never escaped. Paths in `readFile`/`readDir` are relative to the values file.
- A `{{ … }}` inside a YAML comment of a `.gotmpl` file is still executed.
- The helmfile plugin renders with `HELMFILE_TEMPLATE_OPTIONS=--include-crds`; `render-app.sh` does the same.
- External Secrets refresh every hour; force with
  `kubectl --context k8s01 -n <ns> annotate externalsecret <name> force-sync=$(date +%s) --overwrite`.
- Removing a field of the argo-cd release that existed at bootstrap: the `helm` field manager still owns it,
  so Argo CD's server-side apply leaves it in place. Remove the leftover with a guarded `kubectl patch`.

## Useful commands

```bash
./bootstrap.sh status
scripts/render-app.sh --all
scripts/vault.sh status
kubectl --context k8s01 -n argo get applications
kubectl --context k8s01 -n argo port-forward svc/argo-cd-server 8080:80
```
