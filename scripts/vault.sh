#!/usr/bin/env bash
# Operate the in-cluster Vault (app helm-charts/vault). Everything runs through "kubectl exec" on
# vault-0; tokens and secret values travel on stdin, never on a command line.
#
#   scripts/vault.sh status              seal status + secrets present under secret/<prefix>/
#   scripts/vault.sh init                first time only: init (1 key share), unseal, save keys locally
#   scripts/vault.sh unseal              after every restart of vault-0 (Vault starts sealed)
#   scripts/vault.sh configure           KV v2 mount, Kubernetes auth, policy + role for External Secrets
#   scripts/vault.sh autounseal-secret   Secret vault-unseal (unseal key) for the auto-unseal CronJob
#   scripts/vault.sh oidc                login with Keycloak (realm keycloak.realm in environment.yaml, client vault): /vault/admin → admin, /vault/viewer → viewer
#   scripts/vault.sh put <name> k1 k2…   prompt for each key (hidden) and write secret/<prefix>/<name>
#
# Keys and root token: $VAULT_INIT_FILE (default ~/.config/homelab/vault-init.json, mode 600). Keep a copy
# offline (password manager): losing it means losing every secret in Vault.
# Secrets the platform expects (docs/runbooks/vault.md):
#   put cloudflare api-token     put grafana admin-user admin-password
set -euo pipefail

CONTEXT="k8s01"
NS="vault"
POD="vault-0"
KV_MOUNT="secret"
PREFIX="homelab"
INIT_FILE="${VAULT_INIT_FILE:-$HOME/.config/homelab/vault-init.json}"

fail() { echo "✘ $*" >&2; exit 1; }
ok() { echo "✔ $*"; }
k() { kubectl --context "$CONTEXT" "$@"; }
vexec() { k -n "$NS" exec -i "$POD" -c vault -- "$@"; }

# Run a shell snippet in the pod with VAULT_TOKEN read from the first stdin line; the rest of stdin
# (if any) is passed through to the snippet.
with_token() {
    local snippet="$1"
    shift
    { root_token; cat; } | vexec sh -c "read -r VAULT_TOKEN; export VAULT_TOKEN; $snippet"
}
root_token() {
    [ -f "$INIT_FILE" ] || fail "no $INIT_FILE (run init, or restore it from your offline copy)"
    jq -r '.root_token' "$INIT_FILE"
}
# "vault status" exits 2 while sealed: never let that abort the script (set -e + pipefail)
vstatus() { vexec vault status -format=json 2>/dev/null || true; }
sealed() { vstatus | jq -r '.sealed'; }

for t in kubectl jq; do command -v "$t" >/dev/null || fail "$t not found"; done
[ "$(k get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)" = "k8s01" ] ||
    fail "context $CONTEXT is not the homelab (node k8s01) — refusing"
k -n "$NS" get pod "$POD" >/dev/null 2>&1 || fail "pod $NS/$POD not found (is the vault app synced?)"

cmd="${1:-status}"
shift || true
case "$cmd" in
    status)
        vexec vault status || true
        if [ "$(sealed)" = "false" ] && [ -f "$INIT_FILE" ]; then
            echo
            echo "Secrets under $KV_MOUNT/$PREFIX/:"
            : | with_token "vault kv list -format=json $KV_MOUNT/$PREFIX 2>/dev/null || echo '[]'" | jq -r '.[]' | sed 's/^/  /'
        fi
        ;;
    init)
        initialized="$(vstatus | jq -r '.initialized')"
        [ "$initialized" = "false" ] || fail "Vault is already initialized"
        [ ! -e "$INIT_FILE" ] || fail "$INIT_FILE already exists — refusing to overwrite it"
        mkdir -p "$(dirname "$INIT_FILE")"
        umask 077
        vexec vault operator init -key-shares=1 -key-threshold=1 -format=json >"$INIT_FILE"
        chmod 600 "$INIT_FILE"
        ok "initialized — keys saved to $INIT_FILE (copy it to your password manager now)"
        "$0" unseal
        ;;
    unseal)
        [ "$(sealed)" = "true" ] || { ok "already unsealed"; exit 0; }
        [ -f "$INIT_FILE" ] || fail "no $INIT_FILE"
        # "vault operator unseal -" does not read stdin; "vault write key=-" does
        jq -j '.unseal_keys_b64[0]' "$INIT_FILE" | vexec vault write sys/unseal key=- >/dev/null
        [ "$(sealed)" = "false" ] && ok "unsealed" || fail "still sealed"
        ;;
    configure)
        [ "$(sealed)" = "false" ] || fail "Vault is sealed — run unseal first"
        : | with_token "
            set -e
            vault secrets list -format=json | grep -q '\"$KV_MOUNT/\"' || vault secrets enable -path=$KV_MOUNT -version=2 kv
            vault auth list -format=json | grep -q '\"kubernetes/\"' || vault auth enable kubernetes
            vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc:443 >/dev/null
            printf '%s\n' \
                'path \"$KV_MOUNT/data/$PREFIX/*\" { capabilities = [\"read\"] }' \
                'path \"$KV_MOUNT/metadata/$PREFIX/*\" { capabilities = [\"read\", \"list\"] }' |
                vault policy write external-secrets-read - >/dev/null
            vault write auth/kubernetes/role/external-secrets \
                bound_service_account_names=external-secrets \
                bound_service_account_namespaces=external-secrets \
                policies=external-secrets-read ttl=1h >/dev/null
            # Workload apps (homelab-gitops-apps): ServiceAccount vault-reader of a namespace labelled
            # staffops.space/tier=apps reads only $KV_MOUNT/$PREFIX/apps/<its namespace>/* (templated policy)
            accessor=\$(vault read -field=accessor sys/auth/kubernetes)
            printf '%s\n' \
                \"path \\\"$KV_MOUNT/data/$PREFIX/apps/{{identity.entity.aliases.\$accessor.metadata.service_account_namespace}}/*\\\" { capabilities = [\\\"read\\\"] }\" \
                \"path \\\"$KV_MOUNT/metadata/$PREFIX/apps/{{identity.entity.aliases.\$accessor.metadata.service_account_namespace}}/*\\\" { capabilities = [\\\"read\\\", \\\"list\\\"] }\" |
                vault policy write apps-read - >/dev/null
            vault write auth/kubernetes/role/apps \
                bound_service_account_names=vault-reader \
                bound_service_account_namespace_selector='{\"matchLabels\":{\"staffops.space/tier\":\"apps\"}}' \
                policies=apps-read ttl=1h >/dev/null
        "
        ok "KV v2 at $KV_MOUNT/, Kubernetes auth, policies external-secrets-read + apps-read, roles external-secrets + apps"
        ;;
    autounseal-secret)
        # The key goes from the local init file to the cluster on stdin; it never touches git or a command line
        [ -f "$INIT_FILE" ] || fail "no $INIT_FILE"
        jq -j '.unseal_keys_b64[0]' "$INIT_FILE" |
            k -n "$NS" create secret generic vault-unseal --from-file=key=/dev/stdin --dry-run=client -o yaml |
            k apply -f - >/dev/null
        ok "Secret $NS/vault-unseal written; CronJob vault-autounseal unseals vault-0 within 15 minutes of a restart"
        ;;
    oidc)
        # Needs the Keycloak realm (keycloak app synced) and secret/<prefix>/oidc with key "vault"
        [ "$(sealed)" = "false" ] || fail "Vault is sealed — run unseal first"
        domain="$(yq '.domain' "$(dirname "$0")/../helm-charts/environment.yaml")"
        realm="$(yq '.keycloak.realm' "$(dirname "$0")/../helm-charts/environment.yaml")"
        issuer="https://keycloak.$domain/realms/$realm"
        : | with_token "
            set -e
            secret=\$(vault kv get -field=vault $KV_MOUNT/$PREFIX/oidc)
            vault auth list -format=json | grep -q '\"oidc/\"' || vault auth enable oidc
            printf '%s' \"\$secret\" | vault write auth/oidc/config oidc_discovery_url=$issuer \
                oidc_client_id=vault oidc_client_secret=- default_role=default >/dev/null
            vault write auth/oidc/role/default role_type=oidc user_claim=preferred_username \
                groups_claim=groups oidc_scopes=profile,email,groups token_policies=default token_ttl=8h \
                allowed_redirect_uris=https://vault.$domain/ui/vault/auth/oidc/oidc/callback \
                allowed_redirect_uris=http://localhost:8250/oidc/callback >/dev/null
            printf '%s\n' 'path \"*\" { capabilities = [\"create\", \"read\", \"update\", \"delete\", \"list\", \"sudo\"] }' |
                vault policy write admin - >/dev/null
            printf '%s\n' 'path \"*\" { capabilities = [\"read\", \"list\"] }' | vault policy write viewer - >/dev/null
            accessor=\$(vault read -field=accessor sys/auth/oidc)
            # Keycloak groups /vault/admin and /vault/viewer (claim groups, full path) → external groups
            for role in admin viewer; do
                vault write identity/group name=vault-\$role type=external policies=\$role >/dev/null
                gid=\$(vault read -field=id identity/group/name/vault-\$role)
                vault read -field=alias identity/group/name/vault-\$role 2>/dev/null | grep -q \"\$accessor\" ||
                    vault write identity/group-alias name=/vault/\$role mount_accessor=\$accessor canonical_id=\$gid >/dev/null
            done
            # group of the previous model (Keycloak group admins)
            vault delete identity/group/name/admins >/dev/null 2>&1 || true
        "
        ok "OIDC login via $issuer (client vault); /vault/admin → policy admin, /vault/viewer → policy viewer"
        echo "  UI: https://vault.$domain → method OIDC, role default.  CLI: vault login -method=oidc"
        ;;
    put)
        name="${1:-}"
        shift || true
        [ -n "$name" ] && [ $# -gt 0 ] || fail "usage: scripts/vault.sh put <name> <key> [<key>…]"
        [ "$(sealed)" = "false" ] || fail "Vault is sealed — run unseal first"
        json='{}'
        for key in "$@"; do
            read -r -s -p "  $name/$key: " value </dev/tty
            echo
            [ -n "$value" ] || fail "empty value for $key"
            json="$(jq -c --arg k "$key" --arg v "$value" '. + {($k): $v}' <<<"$json")"
        done
        with_token "vault kv put $KV_MOUNT/$PREFIX/$name - >/dev/null" <<<"$json"
        ok "wrote $KV_MOUNT/$PREFIX/$name ($*)"
        echo "  External Secrets picks it up within 1h; to force: kubectl --context $CONTEXT -n <ns> annotate externalsecret <name> force-sync=\$(date +%s) --overwrite"
        ;;
    *)
        sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
esac
