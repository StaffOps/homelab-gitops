# drafts

Configuration kept for later; nothing here is deployed (Argo CD only reads `helm-charts/` apps listed in
the ApplicationSet). To promote a draft: move it to `helm-charts/<app>/` following the app conventions in
AGENTS.md, render it with `scripts/render-app.sh`, then add it to the ApplicationSet.

| Draft | State |
|-------|-------|
| `tempo/` | values for grafana/tempo-distributed (local trace backend, 4 ingesters, replication 2): sized for more than one node — review before use |
