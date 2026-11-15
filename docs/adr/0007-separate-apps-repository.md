# 0007 — Workload apps in a separate repository (homelab-gitops-apps)

- Status: Accepted
- Date: 2026-11-15

## Context

This repository is the platform (Argo CD, secrets, identity, networking, observability, data, backups) and will
grow into a multi-cluster platform. Workload apps (agents, scorecards, anomaly detection, …) change much more
often, have other owners and should not be able to break or read the platform.

## Decision

- Apps live in [StaffOps/homelab-gitops-apps](https://github.com/StaffOps/homelab-gitops-apps), same helmfile
  conventions, no `helm-charts/` prefix: `<app>/helmfile.yaml.gotmpl` and one `<app>/<release>/` directory per
  release. The repo carries a copy of the platform contract (`environment.yaml`: domain, gateway, storage class),
  because the helmfile plugin renders one repository.
- ApplicationSet `apps` (here, `argo-cd-raw`) uses a **git directory generator** on `*/*`: one Application per
  release directory, `--selector name=<dir>`, namespace = app directory, skipping `_*` (templates, drafts). Adding
  or removing an app needs no commit here. App namespaces get the label `staffops.space/tier=apps`.
- AppProject `apps`: source = the apps repo only; destinations = any namespace except the platform and system ones;
  cluster-scoped objects = Namespace only; no ResourceQuota/LimitRange.

## Consequences

- ADR 0002 moved away from a directory generator because a directory without a matching release (or a helmfile
  namespace different from the directory) produced empty or misplaced Applications silently. The apps repo keeps
  the generator for self-service and guards against that with `scripts/render-app.sh` (every release has its
  directory, namespace = app directory, no cluster-scoped kinds besides Namespace).
- Anything cluster-scoped an app needs (CRDs, operators, ClusterRoles, dashboards in Grafana folders) is a platform
  change here.
- New platform namespaces must be added to the deny list of `appproject-apps.yaml`.
- Open: apps still could use ClusterSecretStore `vault` (all of `homelab/*`). Planned: Vault path
  `homelab/apps/<app>` + a store limited to namespaces labelled `staffops.space/tier=apps`, and the platform store
  limited to the platform namespaces.
