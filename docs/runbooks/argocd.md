# Argo CD

UI: `https://argocd.staffops.space`, or without the Gateway:
`kubectl --context k8s01 -n argo port-forward svc/argo-cd-server 8080:80` → `http://localhost:8080`.

## An app is OutOfSync / Degraded

```bash
kubectl --context k8s01 -n argo get applications
kubectl --context k8s01 -n argo get application <app> -o jsonpath='{.status.conditions}' | jq
```

- `ComparisonError` / plugin errors: render it locally, `scripts/render-app.sh <app>` shows the same failure.
- Missing CRD kinds right after install: wait, the retry policy (10 tries, up to 5 min apart) picks them up
  once the owning app synced. A manual "Sync" also works.
- `SecretSyncedError` on an ExternalSecret: [vault.md](vault.md).

## Argo CD cannot sync its own fix

Symptoms: application controller or repo-server crash-looping after a change under `helm-charts/argo/`
(typical cause: invalid YAML in an `argocd-cm` value).

1. Revert or fix the change on `main` and push.
2. `./bootstrap.sh apply --takeover` — re-applies the `argo-cd` release with Helm from the local checkout
   (must match `origin/main`), asks you to type the context name, then re-applies the seed.
3. `./bootstrap.sh status` until `argo-cd` is Synced/Healthy.

## Uninstall an app

Removing it from the ApplicationSet deletes only the Application (`preserveResourcesOnDeletion`). Then:

```bash
cd helm-charts/<app>
helmfile template --include-crds | kubectl --context k8s01 delete -f - --ignore-not-found
kubectl --context k8s01 delete namespace <namespace>      # also deletes its PVCs and data
```

CRDs of the app are deleted by the first command; check nothing else uses them first.

## Full reinstall

Delete namespace `argo` (Applications keep running workloads), then follow
[first-install.md](first-install.md) from step 3.
