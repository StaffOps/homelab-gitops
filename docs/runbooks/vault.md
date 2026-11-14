# Vault

Vault runs as `vault/vault-0` (standalone, file storage on a 5 Gi `local-path` volume). Everything here goes
through `scripts/vault.sh`, which pins context `k8s01` and passes tokens and values on stdin.

Init file: `~/.config/homelab/vault-init.json` (unseal key + root token, mode 600). Override with
`VAULT_INIT_FILE=…`. Keep an offline copy (password manager).

## Sealed (alert VaultSealed, or after any node reboot)

```bash
scripts/vault.sh status     # Sealed: true
scripts/vault.sh unseal
```

While sealed, existing Kubernetes Secrets keep working; ExternalSecrets fail to refresh and new ones stay
pending. The Vault pod stays Ready while sealed on purpose (its readiness probe accepts sealed/uninitialized),
so `https://vault.staffops.space` still answers and Vault can also be unsealed from the UI.

## Secrets the platform expects

| Command | Used by |
|---------|---------|
| `scripts/vault.sh put cloudflare api-token` | cert-manager, external-dns |
| `scripts/vault.sh put grafana admin-user admin-password` | Grafana |
| `scripts/vault.sh put keycloak admin-user admin-password` | Keycloak (bootstrap admin, first start only) |
| `scripts/vault.sh put otel external-token` | otel-gateway external receiver (token the VPS sends) |
| `scripts/vault.sh put oidc argocd grafana vault` | Keycloak clients ([sso.md](sso.md)) |
| `scripts/vault.sh put dependency-track kek` | Dependency-Track (`openssl rand -base64 32`; keep a copy: losing it loses the secrets DT stores) |
| `scripts/vault.sh put velero access-key-id secret-access-key endpoint` | Velero (R2 API token, see [backup.md](backup.md)) |

`put` replaces the whole secret: pass every key of it each time. Adding an app with a secret: add a row here.

## Force a refresh

```bash
kubectl --context k8s01 -n <namespace> annotate externalsecret <name> force-sync=$(date +%s) --overwrite
kubectl --context k8s01 get externalsecrets -A
```

Pods read Secrets at start: restart the workload after rotating a credential it reads from env.

## External Secrets cannot authenticate

`ClusterSecretStore vault` not Ready, events with `permission denied` or `403`:

1. `scripts/vault.sh status` — unsealed?
2. `scripts/vault.sh configure` — idempotent; recreates mount, auth, policy and role.
3. The role is bound to ServiceAccount `external-secrets/external-secrets`: the External Secrets chart uses
   `fullnameOverride: external-secrets` for that reason.

## Root token hygiene

The root token in the init file is only for `configure`. For day-to-day reads use the UI
(`https://vault.staffops.space`) with it sparingly, or create a personal token/userpass later.

## Lost the Vault volume

Re-run `scripts/vault.sh init` on the empty Vault (move the old init file away first), `configure`, then
`put` every secret again from the password manager. The platform recovers on the next ExternalSecret refresh.
