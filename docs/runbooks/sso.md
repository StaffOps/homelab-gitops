# Single sign-on (Keycloak)

Keycloak (`https://keycloak.staffops.space`) holds the realm `staffops` (`keycloak.realm` in
`helm-charts/environment.yaml`), applied by the PostSync Job `keycloak/keycloak-realm-import`
(keycloak-config-cli, `helm-charts/keycloak/keycloak-raw`) after every sync of the `keycloak` app.

**Groups:** for every tool in `keycloak.apps` the realm has `/<tool>/admin` and `/<tool>/viewer`. The claim
`groups` carries the full path (`/argocd/admin`), so each tool only reacts to its own groups. Give a user
access by joining the groups of the tools they need. Client secrets: Vault `homelab/oidc` (keys `argocd`,
`grafana`, `vault`) and `homelab/harbor` (`oidc-client-secret`); `dependency-track` is a public client (browser login, PKCE).

| Tool | Login | `/<tool>/admin` | `/<tool>/viewer` | other users |
|------|-------|-----------------|------------------|-------------|
| Argo CD | "Log in via Keycloak" | `role:admin` | `role:readonly` | no access |
| Grafana | "Sign in with Keycloak" | Admin | Viewer | login refused |
| Vault | method OIDC, role `default` | policy `admin` | policy `viewer` (read/list) | `default` policy only |
| Harbor | "Login via OIDC provider" (Keycloak) | system admin | onboarded user; project access by adding the group to a project | onboarded, no project access |
| Dependency-Track | "Login with Keycloak" | team mapped in the UI (below) | team mapped in the UI | no permissions |

Local logins stay as break-glass: Argo CD `admin`, Grafana `admin` (Vault `homelab/grafana`), Harbor `admin`
(Vault `homelab/harbor`), Vault root token.

## Add a tool

Add it to `keycloak.apps` (creates its two groups on the next sync), create its client in
`keycloak-raw`, and map `/<tool>/admin` and `/<tool>/viewer` in the tool's own config. Add a row above.

## Automation client (realm import)

The realm import Job logs in as the master-realm client `keycloak-config-cli` (client_credentials), never
as a person. Create it once in the admin console:

1. Realm `master` → Clients → Create client → Client ID `keycloak-config-cli` → Next → *Client
   authentication* on, *Service accounts roles* on, other flows off → Save.
2. Tab *Service accounts roles* → Assign role → filter *realm roles* → `admin`.
   Tab *Advanced* → *OpenID Connect Compatibility Modes* → **Use refresh tokens for client credentials grant: On**
   → Save. Without it Keycloak 26.8 issues the token on a transient session that its own admin API rejects
   (401, introspection `active:false`).
   Tab *Client scopes* → Add client scope → `kc-admin-api` → Add → **Default**. Since Keycloak 26.8.2 the
   Admin REST API answers 401 to any token without this scope (only `admin-cli` and `security-admin-console`
   get it on upgrade).
3. Tab *Credentials* → copy the client secret →
   `scripts/vault.sh put keycloak-automation client-secret`.

## MCP servers

`https://mcp.staffops.space/<name>` (kubernetes, grafana, argocd, tempo, dependency-track, keycloak), all read-only
(keycloak-mcp has write tools, but its service account only holds realm-management view/query roles). The Gateway rejects
any request without a Keycloak JWT of realm `staffops` whose `groups` contain `/mcp/admin` or `/mcp/viewer`
(gateway-raw: RequestAuthentication + AuthorizationPolicy). People join one of those groups; services use
their own client with client_credentials (`hermes`, `backstage`, secrets in Vault `homelab/oidc`) and their
service-account users are in `/mcp/viewer`:

```bash
curl -s https://keycloak.staffops.space/realms/staffops/protocol/openid-connect/token \
  -d grant_type=client_credentials -d client_id=hermes -d client_secret=<secret> | jq -r .access_token
# then: Authorization: Bearer <token> on https://mcp.staffops.space/kubernetes
```

New service: add it to the client list in `keycloak-raw` (clients and users), add its secret to
`homelab/oidc`, sync. New MCP server: a Deployment/Service in `helm-charts/mcp-servers`, a rule in its route.

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
