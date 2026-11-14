#!/usr/bin/env bash
# Bootstrap the homelab: prerequisites + Argo CD (the only manual step; everything else is GitOps).
#
#   ./bootstrap.sh diff              # default: checks + what would change (applies nothing)
#   ./bootstrap.sh apply             # checks + prerequisite CRDs + Argo CD + seed + wait + summary
#   ./bootstrap.sh status            # Argo CD pods, ApplicationSets, Applications and access commands
#   ./bootstrap.sh apply --takeover  # recovery only: re-apply Argo CD with Helm over a self-managed install
#
# Once installed, Argo CD manages itself (Application argo-cd, path helm-charts/argo on main). From then on
# the Argo CD release changes by commit + push, never by this script: Helm and Argo CD would fight over the
# same fields (server-side apply). apply then only refreshes the prerequisite CRDs; --takeover is the
# explicit, confirmed escape hatch for recovery.
#
# Every kubectl/helm call is pinned to context k8s01 and the node name is checked first: this machine
# also has other clusters in its kubeconfig.
set -euo pipefail

CONTEXT="k8s01"
NODE="k8s01"
NAMESPACE="argo"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:-diff}"
TAKEOVER=false
[[ "${2:-}" == "--takeover" ]] && TAKEOVER=true
GIT_BRANCH="main"

# Prerequisite CRDs, outside Argo CD: the Gateway API (Istio, the gateway app and every HTTPRoute need it;
# kubeadm ships none) and prometheus-operator (so every app can ship ServiceMonitors).
GATEWAY_API_VERSION="v1.6.3"      # standard channel
PROM_CRDS_CHART_VERSION="33.0.2"  # prometheus-operator-crds (operator v0.95.x, kube-prometheus-stack 93.x)

# --- output helpers ----------------------------------------------------------
if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'; else B="" G="" Y="" R="" C="" N=""; fi
STEP=0
step() { STEP=$((STEP + 1)); printf '\n%s[%d] %s%s\n' "$B$C" "$STEP" "$1" "$N"; }
ok()   { printf '  %s✔%s %s\n' "$G" "$N" "$1"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$1"; }
fail() { printf '  %s✘ %s%s\n' "$R" "$1" "$N" >&2; exit 1; }
kv()   { printf '  %-22s %s\n' "$1" "$2"; }
k()    { kubectl --context "$CONTEXT" "$@"; }

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
[[ "$MODE" =~ ^(diff|apply|status)$ ]] || usage
if $TAKEOVER && [[ "$MODE" != "apply" ]]; then usage; fi

ARGO_DIR="helm-charts/argo"
ARGO_CD_PATHS=("$ARGO_DIR/" "helm-charts/environment.yaml")
git_state() {
    local dirty unpushed head synced
    git -C "$ROOT" fetch -q origin "$GIT_BRANCH" 2>/dev/null || warn "git fetch failed — comparing with the last fetched origin/$GIT_BRANCH"
    dirty="$(git -C "$ROOT" status --porcelain -- "${ARGO_CD_PATHS[@]}")"
    unpushed="$(git -C "$ROOT" log --oneline "origin/$GIT_BRANCH..HEAD" -- "${ARGO_CD_PATHS[@]}")"
    head="$(git -C "$ROOT" rev-parse --short "origin/$GIT_BRANCH")"
    synced="$(k -n "$NAMESPACE" get application argo-cd -o jsonpath='{.status.sync.revision}' 2>/dev/null | cut -c1-7)"
    kv "origin/$GIT_BRANCH" "$head"
    kv "Argo CD synced" "${synced:-unknown} ($(k -n "$NAMESPACE" get application argo-cd -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null))"
    if [[ -n "$dirty" ]]; then warn "uncommitted changes to the argo-cd release (not in the cluster until committed and pushed):"; sed 's/^/      /' <<<"$dirty"; fi
    if [[ -n "$unpushed" ]]; then warn "commits to the argo-cd release not pushed yet:"; sed 's/^/      /' <<<"$unpushed"; fi
    [[ -z "$dirty" && -z "$unpushed" ]]
}

summary() {
    step "Argo CD status"
    k -n "$NAMESPACE" get pods -o wide
    echo
    k -n "$NAMESPACE" get applicationsets,applications \
        -o custom-columns='NAME:.metadata.name,KIND:.kind,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision' \
        2>/dev/null || warn "no ApplicationSets/Applications yet"
    printf '\n%sAccess (until the Gateway and DNS are up):%s\n' "$B" "$N"
    echo "  kubectl --context $CONTEXT -n $NAMESPACE port-forward svc/argo-cd-server 8080:80"
    echo "  open http://localhost:8080  (user: admin)"
    echo "  kubectl --context $CONTEXT -n $NAMESPACE get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
}

printf '%sBootstrap — context %s — mode: %s%s\n' "$B" "$CONTEXT" "$MODE" "$N"

# --- 1. cluster guard (always, also for status) -------------------------------
step "Checking cluster"
command -v kubectl >/dev/null || fail "kubectl not found"
kubectl config get-contexts "$CONTEXT" >/dev/null 2>&1 || fail "kube context $CONTEXT not found (docs/runbooks/node.md: add the kubeconfig)"
nodes="$(k get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)" || fail "cannot reach the API of context $CONTEXT"
[[ "$nodes" == "$NODE" ]] || fail "context $CONTEXT has nodes '$nodes', expected only '$NODE' — refusing to continue"
ok "context $CONTEXT → node $NODE ($(k get node "$NODE" -o jsonpath='{.status.nodeInfo.kubeletVersion}'))"

if [[ "$MODE" == "status" ]]; then summary; exit 0; fi

# --- 2. tools ----------------------------------------------------------------
step "Checking tools"
for t in kubectl helm helmfile yq git; do
    command -v "$t" >/dev/null || fail "$t not found"
    ok "$t"
done
helm plugin list 2>/dev/null | grep -q '^diff' || fail "helm-diff plugin missing: helm plugin install https://github.com/databus23/helm-diff"
ok "helm-diff plugin"

# --- 3. node ready for the platform ------------------------------------------
step "Checking node (docs/runbooks/node.md)"
ready="$(k get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
[[ "$ready" == "True" ]] || fail "node $NODE is not Ready (CNI not running?)"
ok "node Ready"
if k get node "$NODE" -o jsonpath='{.spec.taints[*].key}' | grep -q 'node-role.kubernetes.io/control-plane'; then
    warn "control-plane taint present: platform pods will not schedule on the only node (untaint it in Ansible)"
    [[ "$MODE" == "diff" ]] || fail "remove the control-plane taint first"
else ok "no control-plane taint"; fi
other_default="$(k get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{" "}{end}' | sed 's/local-path//; s/ //g')"
if [[ -z "$other_default" ]]; then ok "no other default StorageClass"
else warn "default StorageClass '$other_default' besides local-path: PVCs without a class become ambiguous"; fi

# --- 4. git: Argo CD syncs origin/main, not the local checkout ----------------
step "Checking git ($GIT_BRANCH)"
git -C "$ROOT" fetch -q origin "$GIT_BRANCH" 2>/dev/null || warn "git fetch failed"
if git -C "$ROOT" cat-file -e "origin/$GIT_BRANCH:$ARGO_DIR/helmfile.yaml.gotmpl" 2>/dev/null; then
    ok "origin/$GIT_BRANCH has $ARGO_DIR"
else
    warn "origin/$GIT_BRANCH has no $ARGO_DIR yet: the root Application would sync nothing until it is pushed"
    [[ "$MODE" == "diff" ]] || fail "push the repository layout first"
fi

# --- 5. prerequisite CRDs (outside Argo CD) -----------------------------------
step "Prerequisites: Gateway API CRDs ($GATEWAY_API_VERSION, standard channel)"
GATEWAY_API_URL="https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
current="$(k get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}' 2>/dev/null || true)"
kv "installed" "${current:-none}"
if [[ "$current" == "$GATEWAY_API_VERSION" ]]; then
    ok "up to date"
elif [[ "$MODE" == "apply" ]]; then
    k apply --server-side --field-manager=bootstrap -f "$GATEWAY_API_URL" >/dev/null && ok "Gateway API $GATEWAY_API_VERSION applied"
else
    warn "would apply Gateway API $GATEWAY_API_VERSION"
fi

step "Prerequisites: prometheus-operator CRDs (chart $PROM_CRDS_CHART_VERSION)"
PROM_ARGS=(prometheus-operator-crds prometheus-operator-crds --repo https://prometheus-community.github.io/helm-charts
    --version "$PROM_CRDS_CHART_VERSION" --namespace kube-system --kube-context "$CONTEXT")
if [[ "$MODE" == "diff" ]]; then
    changes="$(helm diff upgrade --install "${PROM_ARGS[@]}" --context 0 2>/dev/null |
        grep -E '^kube-system, .* has (been added|been removed|changed):' | sed -E 's/^kube-system, //; s/, CustomResourceDefinition.* has (been )?/: /; s/:$//' || true)"
    if [[ -n "$changes" ]]; then sed 's/^/  /' <<<"$changes"; else ok "up to date"; fi
else
    helm upgrade --install "${PROM_ARGS[@]}" --wait >/dev/null && ok "prometheus-operator-crds $PROM_CRDS_CHART_VERSION"
fi

# --- 6. Argo CD --------------------------------------------------------------
# Only the argo-cd release is installed from here. argo-cd-raw (AppProject, ApplicationSet platform) is
# applied by Argo CD itself once the seed — the root Application argo-cd — exists.
seed_manifest() {
    (cd "$ROOT/$ARGO_DIR" && helmfile --selector name=argo-cd-raw template 2>/dev/null) |
        yq 'select(.kind == "Application" and .metadata.name == "argo-cd") | .metadata.namespace = "'"$NAMESPACE"'"'
}
apply_seed() {
    step "Seed: root Application argo-cd"
    local manifest
    manifest="$(seed_manifest)"
    [[ -n "$manifest" ]] || fail "could not render the root Application from argo-cd-raw"
    k -n "$NAMESPACE" apply --server-side --field-manager=bootstrap -f - <<<"$manifest" >/dev/null &&
        ok "Application argo-cd applied (Argo CD now syncs $ARGO_DIR from origin/$GIT_BRANCH)"
}
wait_argo() {
    step "Waiting for Argo CD"
    for d in argo-cd-server argo-cd-repo-server argo-cd-applicationset-controller; do
        k -n "$NAMESPACE" rollout status "deploy/$d" --timeout=300s >/dev/null && ok "$d"
    done
    k -n "$NAMESPACE" rollout status statefulset/argo-cd-application-controller --timeout=300s >/dev/null &&
        ok "argo-cd-application-controller"
}

cd "$ROOT/$ARGO_DIR"
HF=(helmfile --selector name=argo-cd)
SELF_MANAGED=false
k -n "$NAMESPACE" get application argo-cd >/dev/null 2>&1 && SELF_MANAGED=true

if $SELF_MANAGED && ! $TAKEOVER; then
    step "Argo CD: self-managed (Application argo-cd) — Helm step skipped"
    if git_state; then
        ok "$ARGO_DIR matches origin/$GIT_BRANCH — nothing to push"
    else
        warn "to change Argo CD: commit + push $ARGO_DIR to $GIT_BRANCH; Argo CD applies it (Application argo-cd)"
    fi
    printf '\n%sArgo CD release left untouched.%s Recovery only: %s./bootstrap.sh apply --takeover%s\n' "$Y" "$N" "$B" "$N"
    [[ "$MODE" == "apply" ]] && summary
    exit 0
fi

if $TAKEOVER; then
    step "Argo CD: TAKEOVER — re-apply with Helm over the self-managed install"
    git_state || fail "$ARGO_DIR differs from origin/$GIT_BRANCH — commit/push first, otherwise Argo CD reverts the takeover"
    [[ -t 0 ]] || fail "--takeover needs an interactive terminal for confirmation"
    warn "Helm will force ownership of the Argo CD fields (--force-conflicts); Argo CD takes them back on its next sync."
    read -r -p "  Type the context name ($CONTEXT) to continue: " answer
    [[ "$answer" == "$CONTEXT" ]] || fail "confirmation did not match — aborted"
    "${HF[@]}" apply --suppress-secrets --args --force-conflicts
    apply_seed
    wait_argo
    summary
    exit 0
fi

if [[ "$MODE" == "diff" ]]; then
    step "Argo CD: helmfile diff ($ARGO_DIR, release argo-cd)"
    "${HF[@]}" diff --suppress-secrets --context 3 --args --disable-validation || true
    step "Seed: root Application argo-cd (applied after the chart; it then syncs argo-cd + argo-cd-raw)"
    seed_manifest | sed 's/^/  /'
    printf '\n%sDiff only — nothing was applied. Run %s./bootstrap.sh apply%s to install.%s\n' "$Y" "$B" "$N$Y" "$N"
    exit 0
fi

step "Argo CD: helmfile apply ($ARGO_DIR, release argo-cd)"
"${HF[@]}" apply --suppress-secrets
apply_seed
wait_argo
summary
printf '\n%sNext:%s Vault — scripts/vault.sh init, then configure and put (docs/runbooks/vault.md).\n' "$B" "$N"
