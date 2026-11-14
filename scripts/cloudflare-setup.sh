#!/usr/bin/env bash
# Set up the lab zone on Cloudflare (ADR 0004) with a short-lived bootstrap token, and mint the scoped
# token the cluster uses. Idempotent: safe to re-run.
#
#   scripts/cloudflare-setup.sh setup     zone + imported records + scoped cluster token + nameservers to set
#   scripts/cloudflare-setup.sh status    zone status (pending until the registrar points to Cloudflare)
#
# Records that live outside the cluster (other hosts using the same domain) are imported, unproxied, from a
# BIND zone file kept OUT of this repository: $CF_ZONE_FILE (default ~/.config/homelab/<domain>.zone).
# Import them before moving the nameservers, or those hosts lose DNS. The lab's own records are not in that
# file: external-dns creates them.
#
# Bootstrap token (Cloudflare → My Profile → API Tokens → Create Custom Token), delete it afterwards:
#   Account › Account Settings › Read      Zone › Zone › Edit      Zone › DNS › Edit      User › API Tokens › Edit
#   Account resources: your account; Zone resources: all zones from that account.
# It is read from $CF_BOOTSTRAP_TOKEN or a hidden prompt — never pass it as an argument.
#
# The cluster token (DNS Edit + Zone Read on this zone only) is written to $CF_CLUSTER_TOKEN_FILE
# (default ~/.config/homelab/cloudflare-api-token, mode 600). Once Vault runs, store it with
#   scripts/vault.sh put cloudflare api-token   (paste the file content at the hidden prompt)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOMAIN="$(yq '.domain' "$ROOT/helm-charts/environment.yaml")"
API="https://api.cloudflare.com/client/v4"
TOKEN_FILE="${CF_CLUSTER_TOKEN_FILE:-$HOME/.config/homelab/cloudflare-api-token}"
CLUSTER_TOKEN_NAME="homelab-k8s01-dns ($DOMAIN)"
ZONE_FILE="${CF_ZONE_FILE:-$HOME/.config/homelab/$DOMAIN.zone}"

fail() { echo "✘ $*" >&2; exit 1; }
ok() { echo "✔ $*"; }
info() { echo "  $*"; }

for t in curl jq yq; do command -v "$t" >/dev/null || fail "$t not found"; done
[ -n "$DOMAIN" ] && [ "$DOMAIN" != "null" ] || fail "no domain in helm-charts/environment.yaml"

if [ -z "${CF_BOOTSTRAP_TOKEN:-}" ]; then
    read -r -s -p "Cloudflare bootstrap token: " CF_BOOTSTRAP_TOKEN </dev/tty
    echo
fi
[ -n "$CF_BOOTSTRAP_TOKEN" ] || fail "empty token"

# cf METHOD PATH [JSON] — token sent via a curl config on stdin, never on the command line
cf() {
    local method="$1" path="$2" body="${3:-}" out
    out="$(printf 'header = "Authorization: Bearer %s"\n' "$CF_BOOTSTRAP_TOKEN" |
        curl -sS -K - -X "$method" -H 'Content-Type: application/json' ${body:+--data "$body"} "$API$path")"
    if [ "$(jq -r '.success' <<<"$out")" != "true" ]; then
        echo "✘ $method $path: $(jq -c '.errors' <<<"$out")" >&2
        return 1
    fi
    printf '%s' "$out"
}

cf GET /user/tokens/verify >/dev/null || fail "bootstrap token rejected"
ok "bootstrap token valid"

zone_json() { cf GET "/zones?name=$DOMAIN" | jq -c '.result[0] // empty'; }

cmd="${1:-setup}"
case "$cmd" in
    status)
        z="$(zone_json)"
        [ -n "$z" ] || fail "zone $DOMAIN does not exist on Cloudflare (run setup)"
        info "zone:        $DOMAIN ($(jq -r '.status' <<<"$z"))"
        info "nameservers: $(jq -r '.name_servers | join(", ")' <<<"$z")"
        info "public NS:   $(dig +short NS "$DOMAIN" @1.1.1.1 | tr '\n' ' ')"
        [ "$(jq -r '.status' <<<"$z")" = "active" ] && ok "active — Cloudflare is authoritative" ||
            echo "! pending: point the registrar's nameservers to the ones above (Cloudflare re-checks periodically)"
        exit 0
        ;;
    setup) ;;
    *) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

# --- 1. zone -----------------------------------------------------------------
echo "[1] Zone $DOMAIN"
z="$(zone_json)"
if [ -z "$z" ]; then
    # The token may see several accounts: never guess. CF_ACCOUNT selects one by name or id.
    accounts="$(cf GET /accounts | jq -c '[.result[] | {id, name}]')"
    if [ -n "${CF_ACCOUNT:-}" ]; then
        account="$(jq -r --arg a "$CF_ACCOUNT" '[.[] | select(.id == $a or .name == $a)][0].id // empty' <<<"$accounts")"
        [ -n "$account" ] || fail "CF_ACCOUNT '$CF_ACCOUNT' is not visible to the token"
    elif [ "$(jq length <<<"$accounts")" -eq 1 ]; then
        account="$(jq -r '.[0].id' <<<"$accounts")"
    else
        echo "Accounts visible to the token:" >&2
        jq -r '.[] | "  \(.name)"' <<<"$accounts" >&2
        fail "several accounts: set CF_ACCOUNT='<account name>' to choose where the zone is created"
    fi
    [ -n "$account" ] || fail "no account visible to the token (Account Settings: Read)"
    info "account: $(jq -r --arg a "$account" '.[] | select(.id == $a) | .name' <<<"$accounts")"
    z="$(cf POST /zones "$(jq -nc --arg n "$DOMAIN" --arg a "$account" '{name: $n, account: {id: $a}, type: "full", jump_start: false}')" | jq -c '.result')"
    ok "zone created (no automatic scan: records come from the zone file)"
else
    ok "zone already exists ($(jq -r '.status' <<<"$z"))"
fi
ZONE_ID="$(jq -r '.id' <<<"$z")"

# --- 2. records of other hosts (zone file) -----------------------------------
echo "[2] Records from $ZONE_FILE"
if [ -f "$ZONE_FILE" ]; then
    # Cloudflare skips records that already exist, so re-running is safe
    out="$(printf 'header = "Authorization: Bearer %s"\n' "$CF_BOOTSTRAP_TOKEN" |
        curl -sS -K - -X POST -F "file=@$ZONE_FILE" -F 'proxied=false' "$API/zones/$ZONE_ID/dns_records/import")"
    [ "$(jq -r '.success' <<<"$out")" = "true" ] || fail "import failed: $(jq -c '.errors' <<<"$out")"
    ok "imported: $(jq -r '.result.recs_added' <<<"$out") added of $(jq -r '.result.total_records_parsed' <<<"$out") parsed"
    # every name in the file must now exist in the zone
    have="$(cf GET "/zones/$ZONE_ID/dns_records?per_page=500" | jq -r '.result[].name')"
    missing=0
    while read -r name _ _ type _; do
        [[ "$type" =~ ^(A|AAAA|CNAME|MX|TXT|CAA|SRV)$ ]] || continue
        fqdn="$([ "$name" = "@" ] && echo "$DOMAIN" || echo "$name.$DOMAIN")"
        grep -qx "$fqdn" <<<"$have" || { echo "  ✘ $type $fqdn missing"; missing=1; }
    done < <(grep -vE '^\s*(;|\$|$)' "$ZONE_FILE")
    [ "$missing" -eq 0 ] || fail "records missing after import — do not move the nameservers"
    ok "every record of the zone file is present"
else
    echo "  ! no $ZONE_FILE — nothing imported. If other hosts use $DOMAIN, create it before moving the nameservers."
fi
info "records in the zone (external-dns adds the lab's later):"
cf GET "/zones/$ZONE_ID/dns_records?per_page=500" |
    jq -r 'if (.result | length) == 0 then "    (none)" else .result[] | "    \(.type)\t\(.name)\t\(.content)\(if .proxied then "  (proxied)" else "" end)" end'

# --- 3. scoped token for the cluster -----------------------------------------
echo "[3] Cluster token (DNS Edit + Zone Read on $DOMAIN only)"
if ! tokens="$(cf GET /user/tokens 2>/dev/null)"; then
    if [ -s "$TOKEN_FILE" ]; then
        ok "$TOKEN_FILE already present — kept (bootstrap token cannot manage tokens)"
    else
        echo "  ! the bootstrap token lacks User › API Tokens › Edit: create the cluster token by hand:"
        info "  Cloudflare → My Profile → API Tokens → Create Token → template 'Edit zone DNS'"
        info "  Zone Resources: Include › Specific zone › $DOMAIN   (no expiry; name: $CLUSTER_TOKEN_NAME)"
        info "  Save it with: (umask 077; pbpaste > $TOKEN_FILE)"
    fi
    tokens=""
fi
existing="$( [ -n "$tokens" ] && jq -r --arg n "$CLUSTER_TOKEN_NAME" '[.result[] | select(.name == $n)] | length' <<<"$tokens" || echo skip)"
if [ "$existing" = "skip" ]; then
    :
elif [ "$existing" -gt 0 ] && [ -s "$TOKEN_FILE" ]; then
    ok "token '$CLUSTER_TOKEN_NAME' exists and $TOKEN_FILE is present — kept"
else
    [ "$existing" -eq 0 ] || fail "token '$CLUSTER_TOKEN_NAME' exists but $TOKEN_FILE is missing: delete the token in the dashboard and re-run"
    groups="$(cf GET /user/tokens/permission_groups | jq -c '[.result[] | select(.name == "DNS Write" or .name == "Zone Read") | {id}]')"
    [ "$(jq length <<<"$groups")" -eq 2 ] || fail "permission groups 'DNS Write'/'Zone Read' not found"
    body="$(jq -nc --arg n "$CLUSTER_TOKEN_NAME" --arg z "com.cloudflare.api.account.zone.$ZONE_ID" --argjson g "$groups" \
        '{name: $n, policies: [{effect: "allow", resources: {($z): "*"}, permission_groups: $g}]}')"
    value="$(cf POST /user/tokens "$body" | jq -r '.result.value')"
    mkdir -p "$(dirname "$TOKEN_FILE")"
    (umask 077 && printf '%s' "$value" >"$TOKEN_FILE")
    ok "token created → $TOKEN_FILE (shown once by Cloudflare; this file is the only copy)"
fi

# --- 4. what the operator does next ------------------------------------------
echo "[4] Next steps"
z="$(zone_json)"
info "1. At the registrar, set the nameservers of $DOMAIN to:"
jq -r '.name_servers[]' <<<"$z" | sed 's/^/       /'
info "2. scripts/cloudflare-setup.sh status   (until 'active')"
info "3. Delete the bootstrap token in the Cloudflare dashboard."
info "4. Once Vault runs: scripts/vault.sh put cloudflare api-token   (paste the content of $TOKEN_FILE)"
