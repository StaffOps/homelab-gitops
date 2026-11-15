# Backup (Velero and CloudNativePG → Cloudflare R2)

Two tools, one bucket, no overlap:

| What | Tool | Where in the bucket | Schedule / retention |
|------|------|---------------------|----------------------|
| Kubernetes objects of `backup.namespaces` (Cluster CRs, generated Secrets such as `keycloak-db-app`, PVCs) and every volume **except** PostgreSQL data (Vault storage, Dependency-Track data) | Velero | `k8s01/` | 03:00 UTC, 30 days |
| PostgreSQL `keycloak-db`, `dtrack-db`, `harbor-db`, `workflows-db`, `defectdojo-db`: base backup + continuous WAL (point-in-time recovery) | CloudNativePG Barman Cloud plugin | `cnpg/<cluster>/` | base 02:00 UTC + WAL every ≤ 5 min, 30 days |

Monitoring data (Prometheus, Loki, Tempo, Grafana, Alertmanager) and Harbor's image storage are not backed up: metrics
are not worth the cost and images can be pushed again (Harbor's database, with projects, users and policies, is).

## Velero

Velero backs up, every day at 03:00 UTC, the objects **and volume data** of the namespaces listed in
`helm-charts/environment.yaml` `backup.namespaces` (vault, keycloak, dependency-track) to the R2 bucket
`backup.bucket`, prefix `k8s01/`. Volumes go through the node agent (Kopia file-system backup): `local-path`
has no snapshots. Retention 30 days (`backup.ttl`). Alerts: `VeleroBackupFailed`, `VeleroBackupStale`.

Not backed up on purpose: everything Argo CD recreates from git, and Prometheus data (`monitoring`).

## One-time setup (Cloudflare dashboard)

1. R2 → Create bucket `staffops-k8s-local-velero` (location automatic). R2 must be enabled on the account.
2. R2 → Manage API tokens → Create API token: permission **Object Read & Write**, specific bucket
   `staffops-k8s-local-velero`, no expiry. Note the **Access Key ID** and **Secret Access Key** (shown once).
3. `scripts/vault.sh put velero access-key-id secret-access-key endpoint` (hidden prompts). `access-key-id` is the
   32-character Access Key ID, `secret-access-key` the 64-character Secret Access Key, `endpoint` the bucket's
   S3 API URL without the bucket path (`https://<account-id>.r2.cloudflarestorage.com`). The endpoint stays out
   of git: it contains the account id.
4. Check: `kubectl --context k8s01 -n velero get backupstoragelocation default` → `Available`.

## Manual backup

```bash
velero --kubecontext k8s01 backup create manual-$(date +%Y%m%d%H%M) --from-schedule velero-daily
velero --kubecontext k8s01 backup get
velero --kubecontext k8s01 backup describe <name> --details
```

## Restore

Restore one namespace into an empty namespace (delete it first, or restore under another name with
`--namespace-mappings old:new`):

```bash
velero --kubecontext k8s01 restore create --from-backup <backup> --include-namespaces keycloak
velero --kubecontext k8s01 restore describe <restore> --details
```

Full rebuild with data: [disaster-recovery.md](disaster-recovery.md). In short: first-install up to Velero `Available` (Vault put of the R2 token included), then restore
`vault` first (unseal with the **old** unseal key from the offline copy of vault-init.json), then the rest.

## Caveats

- Velero skips the PostgreSQL `pgdata` volumes (Cluster `inheritedMetadata` annotation
  `backup.velero.io/backup-volumes-excludes: pgdata`): a file copy of a running database is not consistent.
  Restore databases from the CloudNativePG backups below.
- Vault data is encrypted at rest by Vault: a restore is useless without the unseal key.

## PostgreSQL (CloudNativePG + Barman Cloud plugin)

Config: `helm-charts/environment.yaml` `backup.postgres`; plugin release `plugin-barman-cloud` in
`helm-charts/cloudnative-pg`; per database an `ObjectStore` `<cluster>-r2`, an ExternalSecret `<cluster>-r2` (the
Velero R2 token, Vault `homelab/velero`) and a `ScheduledBackup` `<cluster>-daily` in the app's `-raw` release
(keycloak, dependency-track). Alerts: `CNPGBackupTooOld` (36 h), `CNPGBackupFailed`, `CNPGWalArchivingFailing`.
Dashboard: Databases → CloudNativePG.

```bash
kubectl --context k8s01 -n keycloak get scheduledbackups,backups
kubectl --context k8s01 -n keycloak get objectstore keycloak-db-r2 -o jsonpath='{.status}'   # first/last recoverability point
kubectl --context k8s01 -n keycloak get cluster keycloak-db -o jsonpath='{.status.conditions}'   # ContinuousArchiving=True
```

On-demand base backup:

```bash
kubectl --context k8s01 -n keycloak create -f - <<'YAML'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
    generateName: keycloak-db-manual-
spec:
    cluster:
        name: keycloak-db
    method: plugin
    pluginConfiguration:
        name: barman-cloud.cloudnative-pg.io
YAML
```

### Restore a database

CloudNativePG restores into a **new** Cluster (it never overwrites a running one). In git, change the app's Cluster
(`keycloak-raw` / `dependency-track-raw`):

1. Stop the app (scale its Deployment/StatefulSet to 0, or disable auto-sync for the app in Argo CD).
2. Replace `bootstrap.initdb` with a recovery from the object store and add the source as an external cluster. Give
   the new Cluster's WAL archive a different `serverName` so it does not write over the backups it restores from:
   ```yaml
   bootstrap:
       recovery:
           source: origin
           # recoveryTarget:            # optional point in time; default = latest WAL
           #     targetTime: "2026-11-15 10:00:00+00"
   externalClusters:
       - name: origin
         plugin:
             name: barman-cloud.cloudnative-pg.io
             parameters:
                 barmanObjectName: keycloak-db-r2
                 serverName: keycloak-db
   plugins:
       - name: barman-cloud.cloudnative-pg.io
         isWALArchiver: true
         parameters:
             barmanObjectName: keycloak-db-r2
             serverName: keycloak-db-r1   # new archive path after the restore
   ```
3. Delete the old Cluster (`kubectl --context k8s01 -n keycloak delete cluster keycloak-db`; its PVC goes with it),
   push, let Argo CD create the restored one, check `kubectl cnpg status`, start the app again.
4. Later, a follow-up commit can move `bootstrap` back to `initdb` (ignored once the cluster exists) and keep the new
   `serverName`.

Full rebuild order: Vault (Velero) → External Secrets → CloudNativePG + plugin → databases (recovery as above) →
apps. Docs: https://cloudnative-pg.io/plugin-barman-cloud/docs/usage/ (restore section).
