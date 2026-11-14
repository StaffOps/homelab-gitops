#!/usr/bin/env bash
# Render a platform app the way Argo CD does and check it, without touching the cluster.
#
#   scripts/render-app.sh --list                 apps (helmfile directories under helm-charts/)
#   scripts/render-app.sh <path>                 e.g. monitoring, cert-manager, argo
#   scripts/render-app.sh <path> --out <file>    keep the rendered manifests
#   scripts/render-app.sh --all                  render every app (what CI would run)
#
# Runs "helmfile template --include-crds" (the plugin's HELMFILE_TEMPLATE_OPTIONS) with the Prometheus and
# Gateway API capabilities. For argo it renders releases argo-cd + argo-cd-raw (the root Application's
# selectors). Checks: render succeeds, every document parses, no unpinned images, no Secret with literal
# data, no Argo CD expression left escaped, ApplicationSet templates reach Argo CD unrendered.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHARTS="$ROOT/helm-charts"
API_ARGS='--api-versions monitoring.coreos.com/v1 --api-versions gateway.networking.k8s.io/v1 --api-versions cert-manager.io/v1 --api-versions external-secrets.io/v1 --api-versions metallb.io/v1beta1'

fail() { echo "✘ $*" >&2; exit 1; }

list_apps() {
    (cd "$CHARTS" && find . -name helmfile.yaml.gotmpl) | sed 's|^\./||; s|/[^/]*$||' | sort -u
}

case "${1:-}" in
    --list) list_apps; exit 0 ;;
    --all)
        rc=0
        for app in $(list_apps); do
            echo "=== $app"
            "$0" "$app" >/dev/null 2>"$(mktemp)" && echo "✔ $app" || { echo "✘ $app"; rc=1; }
        done
        exit $rc
        ;;
    "") fail "usage: scripts/render-app.sh <path> [--out <file>] | --list | --all" ;;
esac

APP="$1"
DIR="$CHARTS/$APP"
[ -f "$DIR/helmfile.yaml.gotmpl" ] || fail "no helm-charts/$APP/helmfile.yaml.gotmpl (apps: $(list_apps | tr '\n' ' '))"
OUT=""
[ "${2:-}" = "--out" ] && OUT="${3:?--out needs a file}"

for t in helmfile helm yq; do command -v "$t" >/dev/null || fail "$t not found"; done

umask 077
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
RENDER="$TMP/render.yaml"

SELECTORS=()
[ "$APP" = "argo" ] && SELECTORS=(--selector name=argo-cd --selector name=argo-cd-raw)

echo "Rendering helm-charts/$APP…"
(cd "$DIR" && helmfile "${SELECTORS[@]}" template --include-crds --args "$API_ARGS" >"$RENDER" 2>"$TMP/err") || {
    grep -vE 'Adding repo|has been added|already exists|Building dependency|Templating release' "$TMP/err" |
        grep -viE 'password|token' | tail -25 >&2
    fail "render failed"
}

yq -e '.' "$RENDER" >/dev/null 2>&1 || fail "rendered output is not valid YAML"

images() {
    # helm test hooks are skipped: Argo CD never applies them
    yq -N 'select(.kind != "CustomResourceDefinition") | select((.metadata.annotations["helm.sh/hook"] // "") | test("^test") | not) | .. | select(tag == "!!map" and has("image")) | .image | select(tag == "!!str")' \
        "$RENDER" 2>/dev/null
}

echo
echo "Objects:"
yq -N '.kind' "$RENDER" | grep -v '^null$' | sort | uniq -c | sort -rn | sed 's/^/  /'
echo
echo "Images:"
{ images | grep -v -E '^(null)?$' || echo "(none)"; } | sort -u | sed 's/^/  /'

problems=0
if images | grep -E ':latest(@|$)|^[^:@]+$' | grep -v -E '^(null)?$'; then
    echo "✘ images without a pinned tag (above)" >&2
    problems=$((problems + 1))
fi
literal=$(yq -N 'select(.kind == "Secret" and (.data != null or .stringData != null)) | .metadata.name' "$RENDER" | grep -v '^null$' || true)
[ -z "$literal" ] || echo "! Secrets with literal data — check none holds a credential: $(echo "$literal" | tr '\n' ' ')" >&2
if grep -n '{{`' "$RENDER" >&2; then
    echo "✘ escaped template left in the output (above)" >&2
    problems=$((problems + 1))
fi
# argocd-cm: every multi-line value is YAML read by the controller; a broken resource.exclusions or
# ignoreDifferences crash-loops it, and then Argo CD cannot sync the fix by itself.
if yq -e 'select(.kind == "ConfigMap" and .metadata.name == "argocd-cm")' "$RENDER" >/dev/null 2>&1; then
    for key in $(yq -N 'select(.kind == "ConfigMap" and .metadata.name == "argocd-cm") | .data | to_entries | .[] | select(.value | test("\n")) | .key' "$RENDER"); do
        if ! K="$key" yq -N 'select(.kind == "ConfigMap" and .metadata.name == "argocd-cm") | .data[strenv(K)]' "$RENDER" | yq -e '.' >/dev/null 2>&1; then
            echo "✘ argocd-cm $key is not valid YAML" >&2
            problems=$((problems + 1))
        fi
    done
fi
# ApplicationSet templates must reach Argo CD as plain {{ ... }} expressions
if yq -e 'select(.kind == "ApplicationSet")' "$RENDER" >/dev/null 2>&1; then
    yq -N 'select(.kind == "ApplicationSet") | .spec.template.metadata.name' "$RENDER" | grep -q '{{ .appName }}' ||
        { echo "✘ ApplicationSet template name is not '{{ .appName }}'" >&2; problems=$((problems + 1)); }
fi

[ -n "$OUT" ] && cp "$RENDER" "$OUT" && echo && echo "Manifests saved to $OUT"
[ "$problems" -eq 0 ] || exit 1
echo
echo "✔ helm-charts/$APP renders"
