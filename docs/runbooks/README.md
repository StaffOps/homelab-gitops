# Runbooks

Step-by-step procedures for operating the lab. Each runbook says when to use it, what you need before you
start, the exact commands, and how to check the result. For the concepts behind them, read
[architecture.md](../architecture.md) and the [glossary](../glossary.md).

## Something is broken

- [vault.md](vault.md#vault-is-sealed) — Vault is sealed (alert `VaultSealed`, after a node reboot).
- [vault.md](vault.md#external-secrets-cannot-authenticate) — ExternalSecrets fail with `permission denied` / `403`.
- [argocd.md](argocd.md#an-app-is-outofsync-or-degraded) — an Argo CD app is OutOfSync or Degraded.
- [argocd.md](argocd.md#argo-cd-cannot-sync-its-own-fix) — Argo CD crash-loops after a change to `helm-charts/argo/`.
- [node.md](node.md#kubectl-fails-with-certificate-errors) — `kubectl --context k8s01` fails, or metrics-server reports x509 errors.
- [backup.md](backup.md#check-the-backups) — alert `VeleroBackupFailed`, `CNPGBackupFailed` or similar.

## Routine operations

- [vault.md](vault.md#write-or-rotate-a-platform-secret) — write or rotate a secret; full list of Vault paths.
- [sso.md](sso.md#give-a-person-access) — give someone access to a tool through Keycloak.
- [sso.md](sso.md#rotate-a-client-secret) — rotate an OIDC client secret.
- [backup.md](backup.md#take-a-manual-backup) — take a manual backup before a risky change.
- [argocd.md](argocd.md#uninstall-an-app) — remove a platform app and its data.
- [node.md](node.md#reboot-the-node) — reboot the node.
- [argo-workflows.md](argo-workflows.md) — Argo Workflows, Events and Rollouts: access, Argo CD integration, watching GitHub.

## Recovery

- [backup.md](backup.md#restore-a-namespace-with-velero) — restore one namespace from Velero.
- [backup.md](backup.md#restore-one-database) — restore one PostgreSQL database to a point in time.
- [disaster-recovery.md](disaster-recovery.md) — rebuild the node from scratch with its data.

## Setup

- [first-install.md](first-install.md) — empty cluster to everything synced.
- [sso.md](sso.md#first-time-setup) — first Keycloak admin, users and the Vault OIDC login.
- [backup.md](backup.md#one-time-setup-r2-bucket-and-token) — create the R2 bucket and token.
- [node.md](node.md#recreate-the-kube-context-on-the-mac) — create the `k8s01` kube context on the Mac.
