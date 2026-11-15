# Documentation

Pick the line that matches what you want to do.

## I want to understand the lab

| Read | You will learn |
|------|----------------|
| [overview.md](overview.md) | the lab in five minutes: big picture, the five ideas, URLs |
| [architecture.md](architecture.md) | how the pieces connect, one diagram per topic |
| [status.md](status.md) | what is done, versions, known limits, backlog |
| [glossary.md](glossary.md) | the words used everywhere else |
| [adr/](adr/README.md) | why each big decision was made |

## I want to change something

| Read | For |
|------|-----|
| [gitops-workflow.md](gitops-workflow.md) | the change flow: edit, render, commit, push |
| [../AGENTS.md](../AGENTS.md) | the hard rules (for people and AI agents) |
| [dashboards/README.md](dashboards/README.md) | how dashboards and alerts are organized and added |

## I need to operate or fix something

| Read | When |
|------|------|
| [runbooks/README.md](runbooks/README.md) | index of every procedure, by situation |
| [runbooks/vault.md](runbooks/vault.md) | Vault sealed, writing or rotating a secret |
| [runbooks/sso.md](runbooks/sso.md) | someone cannot log in, give access to a tool |
| [runbooks/argocd.md](runbooks/argocd.md) | Argo CD stuck or broken |
| [runbooks/disaster-recovery.md](runbooks/disaster-recovery.md) | rebuild the node with its data |

## Reading order for a newcomer

1. [overview.md](overview.md)
2. [architecture.md](architecture.md) sections 1 to 5
3. [gitops-workflow.md](gitops-workflow.md)
4. [AGENTS.md](../AGENTS.md)
5. The runbook of whatever you are about to touch
