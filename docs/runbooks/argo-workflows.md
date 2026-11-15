# Argo Workflows, Events and Rollouts

| Tool | Namespace | Where | What it does here |
|------|-----------|-------|-------------------|
| Argo Workflows | `argo-workflows` | https://argo-workflows.staffops.space (Keycloak) | runs workflows/CronWorkflows; archive in `workflows-db` (CloudNativePG, 30 days), logs and artifacts in R2 (`argo-workflows/` prefix) |
| Argo Events | `argo-events` | — | EventBus `default` (NATS JetStream, 1 server); EventSource `argocd` receives Argo CD notifications; Sensors start workflows |
| Argo Rollouts | `argo-rollouts` | Argo CD UI (Rollout tab) | canary / blue-green for `Rollout` objects, Gateway API traffic split, analysis with the ClusterAnalysisTemplates `success-rate`, `p95-latency`, `pod-restarts` |

## Access (Keycloak)

`/argo-workflows/admin` → ClusterRole `argo-workflows-admin`, `/argo-workflows/viewer` → `argo-workflows-view`, anyone
else: no access (ServiceAccounts `sso-admin` / `sso-viewer` with `workflows.argoproj.io/rbac-rule`). Argo Rollouts
has no UI of its own (its dashboard has no authentication): open a Rollout in Argo CD; promote/abort follow Argo CD
RBAC.

## Integration with Argo CD

- **Argo CD → Argo Events**: the notifications controller posts `on-sync-succeeded`, `on-sync-failed` and
  `on-health-degraded` of every Application to `http://argocd-eventsource-svc.argo-events.svc:12000/argocd`
  (`{app, project, revision, sync, health, phase}`). Sensor `argocd` logs them today; add a trigger to run a workflow.
- **Argo Workflows → Argo CD**: ClusterWorkflowTemplate `argocd-sync` (template `sync`, parameter `app`) syncs and waits
  for an Application as the Argo CD local account `argo-workflows` (only `applications get` and `sync`).
- **Workflow as a sync hook**: a `Workflow` with `argocd.argoproj.io/hook: PostSync` in an app's manifests runs after
  the sync; Argo CD waits for it and shows its result.
- **UI**: Workflow / CronWorkflow / WorkflowTemplate objects in Argo CD link to their page in Argo Workflows;
  Rollouts get the rollout-extension tab.

## Watch a GitHub repository (no webhooks: GitHub cannot reach the lab)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: CronWorkflow
metadata:
    name: watch-my-repo
    namespace: argo-workflows
spec:
    schedules: ["*/5 * * * *"]
    concurrencyPolicy: Forbid
    workflowSpec:
        workflowTemplateRef:
            name: github-watch
            clusterScope: true
        arguments:
            parameters:
                - name: repo
                  value: owner/name
                - name: what
                  value: release # or tag
                - name: on-change
                  value: my-release-pipeline # WorkflowTemplate in argo-workflows, gets parameters repo + version
```

The first run only records the current value (ConfigMap `github-watch-<owner>-<name>-<what>`); later runs submit
`on-change` when it changes. Anonymous GitHub API: 60 requests/h per IP. For more, or private repositories:
`scripts/vault.sh put github token` plus an ExternalSecret `github-token` (key `token`) in `argo-workflows`; the
template uses it when present. Images pushed to Harbor can notify directly (Harbor webhook → an Argo Events
`webhook` EventSource), no polling.

## Secrets

`homelab/argo-workflows`: `oidc-client-secret` (Keycloak client `argo-workflows`, also read by the realm import) and
`argocd-token` (token of the Argo CD account `argo-workflows`). Create the token after Argo CD has the account:

```bash
argocd account generate-token --account argo-workflows   # as an Argo CD admin
vault kv patch secret/homelab/argo-workflows argocd-token=<token>
```
