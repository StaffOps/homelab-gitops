# GitOps workflow

`main` is what runs: every Application syncs automatically with `selfHeal`. A change is safe when it was
rendered locally before the push.

## Change an existing app

1. Edit `helm-charts/<app>/…` (or `helm-charts/environment.yaml` for lab-wide values).
2. `scripts/render-app.sh <app>` — must end with `✔`. Read the object counts and images it prints.
3. Commit only the files of the change (Conventional Commits), push to `main`.
4. Watch it: `kubectl --context k8s01 -n argo get application <app> -w` (or the UI at
   `https://argocd.staffops.space`).

## Change Argo CD itself

Same flow under `helm-charts/argo/`, rendered with `scripts/render-app.sh argo`. Never `helmfile apply` it on
the running cluster (AGENTS.md rule 3). If the change breaks Argo CD so badly it cannot sync the fix, see
[runbooks/argocd.md](runbooks/argocd.md).

## Add an app

1. Create `helm-charts/<app>/helmfile.yaml.gotmpl` following the conventions in AGENTS.md (copy a small app
   such as `external-dns`).
2. Expose it with an HTTPRoute to Gateway `public` (`sectionName: https`), secrets via ExternalSecret.
3. `scripts/render-app.sh <app>`.
4. Write the secrets first (`scripts/vault.sh put …`), so the first sync finds them.
5. Add an element to `helm-charts/argo/argo-cd-raw/resources/applicationset-platform.yaml`; render `argo`.
6. Commit + push both.

## Remove an app

Delete its element from the ApplicationSet and push: the Application goes away but its workloads stay
(`preserveResourcesOnDeletion`). Uninstall explicitly — [runbooks/argocd.md](runbooks/argocd.md#uninstall-an-app).

## Upgrade a chart

Bump `version` in the app's helmfile environment values, read the chart's changelog, render, push. Istio's
four charts move together (`istio.version`). Keep `PROM_CRDS_CHART_VERSION` in `bootstrap.sh` aligned with
the operator version of kube-prometheus-stack and run `./bootstrap.sh apply` for the CRDs.
