# 0002 — Self-managed Argo CD + ApplicationSet with an explicit app list

- Status: Accepted
- Date: 2026-11-13

## Context

The previous layout generated one Application per directory (`step-1/*/*`) and selected the helmfile release
by directory name. Any mismatch (a directory without a release of the same name, a helmfile namespace that
differed from the directory) produced empty or misplaced Applications silently. Argo CD itself was installed
by hand and drifted from git.

## Decision

- Argo CD manages itself: root Application `argo-cd` syncs `helm-charts/argo` (releases `argo-cd` and
  `argo-cd-raw`). `bootstrap.sh` installs it once and then only refreshes prerequisite CRDs.
- One ApplicationSet `platform` with a **list generator**: each element names the app, its helmfile path and
  namespace (optionally selectors and ignoreDifferences). An app runs only when listed.
- Every app is a helmfile rendered by the travisghansen helmfile CMP (`--include-crds`), with versions and
  `enabled` flags in the helmfile environment and lab-wide values in `helm-charts/environment.yaml`.

## Consequences

- Adding an app is two explicit edits (directory + list element); unlisted directories are drafts.
- Never `helm`/`helmfile apply` the argo-cd release on a running cluster (server-side apply conflicts);
  `--takeover` exists for recovery only.
- `scripts/render-app.sh` reproduces the plugin's render locally and is the gate before a push.
