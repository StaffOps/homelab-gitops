#!/usr/bin/env bash
# Operate the in-cluster Vault (app helm-charts/vault). Everything runs through "kubectl exec" on
# vault-0; tokens and secret values travel on stdin, never on a command line.
#
#   scripts/vault.sh status              seal status + secrets present under secret/<prefix>/
#   scripts/vault.sh init                first time only: init (1 key share), unseal, save keys locally
#   scripts/vault.sh unseal              after every restart of vault-0 (Vault starts sealed)
#   scripts/vault.sh configure           KV v2 mount, Kubernetes auth, policy + role for External Secrets
#   scripts/vault.sh put <name> k1 k2…   prompt for each key (hidden) and write secret/<prefix>/<name>
#
# Keys and root token: $VAULT_INIT_FILE (default ~/.config/homelab/vault-init.json, mode 600). Keep a copy
# offline (password manager): losing it means losing every secret in Vault.
# Secrets the platform expects (docs/runbooks/vault.md):
#   put cloudflare api-token     put grafana admin-user admin-password     put minio root-user root-password
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
sealed() { vexec vault status -format=json 2>/dev/null | jq -r '.sealed'; }

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
        initialized="$(vexec vault status -format=json 2>/dev/null | jq -r '.initialized')"
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
        jq -r '.unseal_keys_b64[0]' "$INIT_FILE" | vexec vault operator unseal - >/dev/null
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
        "
        ok "KV v2 at $KV_MOUNT/, Kubernetes auth, policy external-secrets-read, role external-secrets"
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
