# homelab-gitops

GitOps for a single-node kubeadm homelab (`k8s01`). Argo CD installs and keeps every platform app in sync from
this repository, including itself; the only manual steps are the bootstrap and the Vault unseal. Every
service is reachable from the home network at `https://<app>.staffops.space` with a valid certificate.

| Read | For |
|------|-----|
| [docs/architecture.md](docs/architecture.md) | what runs where (app catalog, traffic, secrets) |
| [docs/gitops-workflow.md](docs/gitops-workflow.md) | how to change Argo CD or an app safely |
| [docs/adr/](docs/adr/README.md) | why things are the way they are |
| [docs/runbooks/](docs/runbooks/README.md) | first install, Vault, Argo CD recovery, node |
| [AGENTS.md](AGENTS.md) | rules for agents and operators (`CLAUDE.md` imports it) |

## Layout

```
bootstrap.sh                  entry point: diff | apply | status | apply --takeover
scripts/render-app.sh         render an app like Argo CD does, with checks (before every push)
scripts/vault.sh              Vault: init | unseal | configure | put | status
helm-charts/environment.yaml  values shared by every app (domain, IPs, Vault paths, repo)
helm-charts/argo/             Argo CD (self-managed) + ApplicationSet platform (the app list)
helm-charts/<app>/            platform apps (helmfile + one directory per release)
drafts/                       not deployed
docs/                         architecture, workflow, ADRs, runbooks
```

## Quick start

```bash
./bootstrap.sh diff                 # checks + what would change, applies nothing
./bootstrap.sh apply                # first install: prerequisite CRDs + Argo CD + root Application
scripts/vault.sh init               # once Argo CD has synced the vault app
scripts/vault.sh configure
scripts/vault.sh put cloudflare api-token
./bootstrap.sh status               # Argo CD pods, ApplicationSets, Applications
scripts/render-app.sh <app>         # before every push
```

Requires the kube context `k8s01` (see [docs/runbooks/node.md](docs/runbooks/node.md)), `kubectl`, `helm`
(+ `helm-diff`), `helmfile`, `yq` and `jq`. After the first install Argo CD manages itself: change it by
commit + push to `main`, never with Helm.
