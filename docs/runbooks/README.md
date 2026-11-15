# Runbooks

| Runbook | When |
|---------|------|
| [first-install.md](first-install.md) | empty cluster → everything synced (also full rebuild) |
| [vault.md](vault.md) | Vault sealed, init, writing/rotating secrets, restoring |
| [sso.md](sso.md) | Keycloak login for Argo CD, Grafana and Vault; users, secret rotation |
| [backup.md](backup.md) | Velero and CloudNativePG (Barman Cloud) to Cloudflare R2: setup, manual backup, restore |
| [argocd.md](argocd.md) | Argo CD broken or stuck, uninstalling an app |
| [node.md](node.md) | node and cluster facts, kube context on the Mac, node reboot |
| [argo-workflows.md](argo-workflows.md) | Argo Workflows, Events and Rollouts: access, Argo CD integration, watching GitHub repositories |
