# Single sign-on (Keycloak)

Keycloak (`https://keycloak.staffops.space`) holds the realm `homelab`, applied by the PostSync Job
`keycloak/keycloak-realm-import` (keycloak-config-cli, `helm-charts/keycloak/keycloak-raw`) after every sync of
the `keycloak` app. It defines the group `admins`, the client scope `groups` (claim `groups`) and one
confidential client per app. Client secrets: Vault `homelab/oidc` (keys `argocd`, `grafana`, `vault`).

| App | Login | Admin when |
|-----|-------|-----------|
| Argo CD | "Log in via Keycloak" | in group `admins` (`role:admin`); others get no access |
| Grafana | "Sign in with Keycloak" | in group `admins` (Admin); others Viewer |
| Vault | method OIDC, role `default` | in group `admins` (policy `admin`) |

Local logins stay as break-glass: Argo CD `admin`, Grafana `admin` (Vault `homelab/grafana`), Vault root token.

## First time

1. Keycloak admin console (`https://keycloak.staffops.space/admin`, bootstrap admin from Vault
   `homelab/keycloak`): create a permanent admin in realm `master`, then delete the temporary one.
2. Realm `homelab` → Users → create your user (email verified, set a password) → Groups → join `admins`.
3. `scripts/vault.sh oidc` (once; idempotent) — Vault's OIDC auth method, policy `admin`, group mapping.

## Rotate a client secret

```bash
scripts/vault.sh put oidc argocd grafana vault     # all three keys (put replaces the whole secret)
kubectl --context k8s01 -n argo annotate application keycloak argocd.argoproj.io/refresh=hard --overwrite
```

Then force-sync the ExternalSecrets (`argo/argocd-oidc`, `monitoring/grafana-oidc`,
`keycloak/keycloak-oidc-clients`), re-sync the `keycloak` app (runs the import), restart Grafana and run
`scripts/vault.sh oidc` again.
