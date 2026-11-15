# Argo CD

## What this is about

Argo CD manages itself and every platform app from `main` of this repository. This runbook covers apps that do not
sync, an Argo CD that cannot sync its own fix, uninstalling an app and reinstalling Argo CD. How changes flow is in
[gitops-workflow.md](../gitops-workflow.md).

## When to use it

- An Application is OutOfSync, Degraded, or shows a `ComparisonError`.
- The application controller or repo-server crash-loops after a change under `helm-charts/argo/`.
- You remove a platform app for good.
- Argo CD itself must be reinstalled.

## Before you start

- Kube context `k8s01`.
- A local checkout of this repository that matches `origin/main`.
- The UI: `https://argocd.staffops.space`, or without the Gateway:

    ```bash
    kubectl --context k8s01 -n argo port-forward svc/argo-cd-server 8080:80     # then http://localhost:8080
    ```

## Procedures

### An app is OutOfSync or Degraded

1. List the apps and read the conditions of the broken one:

    ```bash
    kubectl --context k8s01 -n argo get applications
    kubectl --context k8s01 -n argo get application <app> -o jsonpath='{.status.conditions}' | jq
    ```

2. Match the symptom:

    | Symptom | Action |
    |---------|--------|
    | `ComparisonError` or a plugin error | Render it locally: `scripts/render-app.sh <app>` shows the same failure. Fix, render, push. |
    | Missing CRD kinds right after install | Wait: the retry policy (10 tries, up to 5 min apart) picks them up once the owning app synced. A manual "Sync" also works. |
    | `SecretSyncedError` on an ExternalSecret | The secret is missing in Vault: [vault.md](vault.md#if-it-goes-wrong). |
    | Pods Running but not Ready, or connections refused after adding a NetworkPolicy | Ambient mode: see the note below. |

    Expect: after the fix and a push, the app turns Synced/Healthy.

> **Note:** every namespace except `kube-*`, `istio-system`, `calico-system` and `tigera-operator` runs in Istio
> [ambient mode](../glossary.md) (Kyverno labels them). Traffic between mesh Pods arrives on ztunnel's HBONE port
> 15008 and kubelet probes arrive from `169.254.7.127`. A NetworkPolicy must allow TCP 15008 and
> `169.254.7.127/32`, as `helm-charts/argo/argo-cd-raw/resources/networkpolicy-ambient.yaml` does for Argo CD.

### Argo CD cannot sync its own fix

Symptoms: the application controller or repo-server crash-loops after a change under `helm-charts/argo/`. A typical
cause is invalid YAML in an `argocd-cm` value (for example `resource.exclusions`).

1. Revert or fix the change on `main` and push. Render first: `scripts/render-app.sh argo`.
2. Re-apply the `argo-cd` release with Helm from the local checkout:

    > **Warning:** `--takeover` is for recovery only. It re-applies Argo CD with Helm over a self-managed install. Your
    > checkout must match `origin/main`. The script asks you to type the context name, then re-applies the seed.

    ```bash
    ./bootstrap.sh apply --takeover
    ```

3. Wait for Argo CD to manage itself again:

    ```bash
    ./bootstrap.sh status
    ```

    Expect: `argo-cd` Synced/Healthy.

### Uninstall an app

Removing the app from the ApplicationSet deletes only the Application (`preserveResourcesOnDeletion`). The workloads
keep running until you delete them.

1. Remove its element from `helm-charts/argo/argo-cd-raw/resources/applicationset-platform.yaml`, render and push.
2. Delete what the app created:

    > **Warning:** this also deletes the app's CRDs and, with the namespace, its PVCs and data. Check first that
    > nothing else uses those CRDs.

    ```bash
    cd helm-charts/<app>
    helmfile template --include-crds | kubectl --context k8s01 delete -f - --ignore-not-found
    kubectl --context k8s01 delete namespace <namespace>
    ```

    Expect: `kubectl --context k8s01 get namespace <namespace>` returns `NotFound`.

### Full reinstall

1. Delete namespace `argo`. The Applications' workloads keep running.

    ```bash
    kubectl --context k8s01 delete namespace argo
    ```

2. Follow [first-install.md](first-install.md#3-bootstrap) from step 3.

## Check

```bash
./bootstrap.sh status
kubectl --context k8s01 -n argo get applications     # all Synced/Healthy
```

## If it goes wrong

- The render works locally but Argo CD fails: Argo CD syncs `origin/main`, not your checkout. Check that you pushed.
- A field removed from the argo-cd release stays in the cluster: the `helm` field manager from the bootstrap still
  owns it, so Argo CD's server-side apply leaves it. Remove the leftover with a guarded `kubectl --context k8s01 patch`.
- Never run `helm`/`helmfile apply` for the `argo-cd` release on a running cluster, except `--takeover` above.
