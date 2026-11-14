# Backup (Velero → Cloudflare R2)

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

Full rebuild: first-install up to Velero `Available` (Vault put of the R2 token included), then restore
`vault` first (unseal with the **old** unseal key from the offline copy of vault-init.json), then the rest.

## Caveats

- PostgreSQL (CloudNativePG) volumes are copied live: crash-consistent, normally recoverable. For
  point-in-time recovery, add CloudNativePG's own backups (barman-cloud) to R2 later.
- Vault data is encrypted at rest by Vault: a restore is useless without the unseal key.
