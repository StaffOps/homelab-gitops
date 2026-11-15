# Disaster recovery (rebuild the node from scratch)

What comes back on its own and what needs an operator, in order. [first-install.md](first-install.md) is the path for
an empty lab; this page is for rebuilding the **same** lab with its data. Nothing here is automated on purpose: run
it only in a real recovery.

## What git alone restores

Everything declared in the three repositories: node (homelab-ansible), Argo CD and every platform app
(homelab-gitops), workload apps (homelab-gitops-apps), dashboards, alerts, Kyverno policies (ambient labels,
Pod zone), DNS records (external-dns) and certificates (cert-manager).

## What needs a backup or a manual step

| State | Where it comes back from | Step |
|-------|--------------------------|------|
| Every secret (`secret/homelab/*`) | Velero backup of namespace `vault` (daily 03:00 UTC, R2 `k8s01/`) + the **old** unseal key | 4 |
| PostgreSQL: Keycloak (users, group membership, master-realm clients), Dependency-Track (projects, API keys), Harbor (projects, users, policies), Argo Workflows (archive), DefectDojo, Grafana (users, preferences, service-account tokens) | CloudNativePG base backups + WAL in R2 (`cnpg/<cluster>/`), point-in-time | 1 + 5 |
| Argo CD API tokens (accounts `mcp`, `argo-workflows`) | Regenerated: a new Argo CD signs with a new key | 6 |
| Metrics, logs, traces, Harbor images, DefectDojo uploads | Not backed up (accepted) | — |

## 0. Keep these outside the cluster (before any disaster)

- `~/.config/homelab/vault-init.json` (unseal key + root token), offline copy in the password manager.
- The **R2 API token** (access key id, secret access key, endpoint), in the same password manager. Velero needs it
  to restore Vault, and it normally lives *in* Vault (`homelab/velero`): the offline copy breaks that circle.
- The Cloudflare zone file `~/.config/homelab/staffops.space.zone` and the cluster's Cloudflare API token (or a way
  to mint a new one: first-install step 0).

## 1. Before bootstrapping: point the databases at their backups (git)

If the Clusters start with `initdb`, CloudNativePG creates **empty** databases and the Barman Cloud plugin refuses to
archive into the existing backup path. So, before step 3, uncomment the restore keys under `backup.postgres` in
`helm-charts/environment.yaml` and push:

```yaml
        restore: true
        # restoreTargetTime: "2026-11-15 10:00:00+00"   # optional point in time; default: the latest WAL
        restoreFromSuffix: ""                           # "" the first time; "-r1" if the backups came from a previous recovery
        serverSuffix: "-r1"                             # new WAL archive path: never reuse one
```

Every CloudNativePG Cluster (`keycloak-db`, `dtrack-db`, `harbor-db`, `workflows-db`, `defectdojo-db`, `grafana-db`) then renders
`bootstrap.recovery` from its ObjectStore (`<cluster>-r2`, `serverName: <cluster><restoreFromSuffix>`) instead of
`initdb`, and archives its new WAL under `<cluster><serverSuffix>` so it never writes over the backups it restores
from. The recovering Clusters wait (and retry) until their R2 credentials exist, which needs Vault (step 4).

After the recovery: set `restore` back to false (comment it) but **keep `serverSuffix` set**: it is now where the live
backups go, and the next recovery uses it as `restoreFromSuffix`. Without the keys, the templates render exactly as
before (verified: identical output). Upstream reference: https://cloudnative-pg.io/plugin-barman-cloud/docs/usage/
(restore section).

## 2. Node

`homelab-ansible` (kubeadm, Calico, GPU, CoreDNS with 2 replicas), then the kube context `k8s01`
([node.md](node.md)).

## 3. Bootstrap

`./bootstrap.sh apply` ([first-install.md](first-install.md#3-bootstrap)). Argo CD syncs every app; the ones that need
secrets stay degraded until step 4.

## 4. Vault: restore the secrets

The new Vault starts empty. Velero needs the R2 token to read the backup, so:

1. `scripts/vault.sh init` (temporary Vault; move the real `vault-init.json` aside first), `scripts/vault.sh
   configure`, `scripts/vault.sh put velero access-key-id secret-access-key endpoint` from the offline copy. Wait until
   `kubectl --context k8s01 -n velero get backupstoragelocation default` is `Available`.
2. Remove the temporary Vault data and restore the backed-up one:
   ```bash
   kubectl --context k8s01 -n vault scale statefulset vault --replicas=0
   kubectl --context k8s01 -n vault delete pvc --all
   velero --kubecontext k8s01 backup get                      # pick the latest Completed backup
   velero --kubecontext k8s01 restore create --from-backup <backup> --include-namespaces vault \
       --include-resources persistentvolumeclaims,persistentvolumes,pods
   kubectl --context k8s01 -n vault scale statefulset vault --replicas=1
   ```
   Argo CD keeps the rest of the namespace (it owns those objects); only the data volume comes from Velero.
3. Put the **original** `vault-init.json` back in `~/.config/homelab/`, then `scripts/vault.sh unseal`. The restored
   Vault has the old secrets, the old policies and roles (`external-secrets`, `apps`). Run `scripts/vault.sh configure`
   once more: it is idempotent and refreshes the Kubernetes auth config for the new cluster's API.
4. Force the ExternalSecrets ([vault.md](vault.md#force-a-refresh)) and check that they are all `SecretSynced`.

## 5. Databases

With Vault back, the Clusters from step 1 get their R2 credentials and recover. Check each:

```bash
kubectl --context k8s01 get clusters.postgresql.cnpg.io -A          # "Cluster in healthy state"
kubectl --context k8s01 -n keycloak logs keycloak-db-1-full-recovery-<suffix>   # if one is stuck
```

Then the apps that use them (Keycloak, Dependency-Track, Harbor, Argo Workflows, DefectDojo) become Healthy. Keycloak
gets back its users, group memberships and the master-realm client `keycloak-config-cli`; the realm import re-applies
clients and groups from git on top.

## 6. Tokens that cannot be restored

- **Argo CD** (new signing key): generate the tokens again as an Argo CD admin and write them back:
  ```bash
  argocd account generate-token --account mcp              # → vault kv patch secret/homelab/mcp argocd-token=<token>
  argocd account generate-token --account argo-workflows   # → vault kv patch secret/homelab/argo-workflows argocd-token=<token>
  ```
- Force the affected ExternalSecrets; the MCP servers and `argocd-sync` work again.

## 7. Check

[first-install.md](first-install.md#5-check), plus: all Argo CD apps Synced/Healthy, `kubectl get backups.postgresql.cnpg.io
-A` shows a new completed backup per cluster, Grafana → Observability → Alerts overview is empty, logins through
Keycloak work for every tool.
