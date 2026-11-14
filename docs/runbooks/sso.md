# Single sign-on (Keycloak)

Keycloak (`https://keycloak.staffops.space`) holds the realm `staffops` (`keycloak.realm` in
`helm-charts/environment.yaml`), applied by the PostSync Job `keycloak/keycloak-realm-import`
(keycloak-config-cli, `helm-charts/keycloak/keycloak-raw`) after every sync of the `keycloak` app.

**Groups:** for every tool in `keycloak.apps` the realm has `/<tool>/admin` and `/<tool>/viewer`. The claim
`groups` carries the full path (`/argocd/admin`), so each tool only reacts to its own groups. Give a user
access by joining the groups of the tools they need. Client secrets: Vault `homelab/oidc` (keys `argocd`,
`grafana`, `vault`); `dependency-track` is a public client (browser login, PKCE).

| Tool | Login | `/<tool>/admin` | `/<tool>/viewer` | other users |
|------|-------|-----------------|------------------|-------------|
| Argo CD | "Log in via Keycloak" | `role:admin` | `role:readonly` | no access |
| Grafana | "Sign in with Keycloak" | Admin | Viewer | login refused |
| Vault | method OIDC, role `default` | policy `admin` | policy `viewer` (read/list) | `default` policy only |
| Dependency-Track | "Login with Keycloak" | team mapped in the UI (below) | team mapped in the UI | no permissions |

Local logins stay as break-glass: Argo CD `admin`, Grafana `admin` (Vault `homelab/grafana`), Vault root token.

## Add a tool

Add it to `keycloak.apps` (creates its two groups on the next sync), create its client in
`keycloak-raw`, and map `/<tool>/admin` and `/<tool>/viewer` in the tool's own config. Add a row above.

## First time

1. Keycloak admin console (`https://keycloak.staffops.space/admin`, bootstrap admin from Vault
   `homelab/keycloak`): create a permanent admin in realm `master`, then delete the temporary one.
2. Realm `staffops` → Users → create your user (email verified, set a password) → Groups → join the
   `admin` or `viewer` subgroup of each tool.
3. `scripts/vault.sh oidc` (once; idempotent) — Vault's OIDC auth method, policies `admin`/`viewer`, group mapping.
4. Dependency-Track: log in as the local `admin`, Administration → Access Management → OpenID Connect Groups:
   add `/dependency-track/admin` (map to *Administrators*) and `/dependency-track/viewer` (map to a team with
   `VIEW_PORTFOLIO`, `VIEW_VULNERABILITY`, `VIEW_BADGES`).

## Rotate a client secret

```bash
scripts/vault.sh put oidc argocd grafana vault     # all three keys (put replaces the whole secret)
kubectl --context k8s01 -n argo annotate application keycloak argocd.argoproj.io/refresh=hard --overwrite
```

Then force-sync the ExternalSecrets (`argo/argocd-oidc`, `monitoring/grafana-oidc`,
`keycloak/keycloak-oidc-clients`), re-sync the `keycloak` app (runs the import), restart Grafana and run
`scripts/vault.sh oidc` again.
