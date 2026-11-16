# Where we are

Snapshot of the lab on **2026-11-15**. Update it when something important changes: a new app, a decision, a closed
or new backlog item.

## In one paragraph

The platform is complete and stable: 26 platform apps plus Argo CD itself, all synced and healthy, every service behind one Gateway with TLS
and Keycloak login, secrets only in Vault (with per-app isolation), every namespace in the Istio ambient mesh,
dashboards and alert rules for every service, databases backed up to R2 with point-in-time recovery, and a written
disaster-recovery procedure. Workload apps have their own repository ([homelab-gitops-apps](https://github.com/StaffOps/homelab-gitops-apps)),
which is ready but still empty.

## What is running (versions)

| Area | Component | Version |
|------|-----------|---------|
| Base | Kubernetes (kubeadm), Calico | v1.37.2, v3.33 |
| Delivery | Argo CD (chart 10.18.0) | v3.6.1 |
| | Argo Rollouts, Workflows, Events | v1.10.2, v4.1.6, v1.9.11 |
| | KEDA | 2.21.0 |
| Network | Istio (ambient) | 1.30.8 |
| | MetalLB, cert-manager, external-dns | 0.16.2, v1.21.3, chart 1.23.0 |
| Identity and secrets | Keycloak | 26.8.x |
| | Vault (chart 0.34.1), External Secrets | 2.0.4, 2.15.0 |
| | Kyverno | v1.20.0 |
| Observability | kube-prometheus-stack, Loki, Tempo | 93.3.0, 3.7, 3.1 |
| | OpenTelemetry Operator chart, OBI | 0.129.0, v1.0.0 |
| Data | CloudNativePG + Barman Cloud plugin | 1.30.1 + v0.16.0 |
| | Velero | 1.18.2 |
| Security | Harbor, Dependency-Track, DefectDojo | 2.15.4, 5.2.x, 3.5.103 |
| AI | llama.cpp (Vulkan, GT 740), MCP servers | pinned image, 7 servers |

The exact pins are in each `helm-charts/<app>/helmfile.yaml.gotmpl`.

## Built recently (2026-11-13 → 2026-11-15)

- **Observability**: 51 dashboards, one or more per service (official upstream + curated), "Active alerts" table
  in each one, the "Alerts overview" dashboard, alert rules from upstream mixins, control-plane / Calico / GPU /
  MCP metrics.
- **New apps**: Harbor, DefectDojo 3.5, Argo Rollouts, Argo Workflows, Argo Events (integrated with Argo CD).
- **Repositories**: moved to the `StaffOps` organization, license MIT-0, separate `homelab-gitops-apps` repository
  with its ApplicationSet and AppProject.
- **Security**: Istio ambient mode on every namespace (Kyverno), per-app Vault isolation, Dependency-Track admin
  password out of the default and OIDC groups mapped.
- **Data**: CloudNativePG backups to R2 (6 clusters, Grafana included), restore switch, disaster-recovery runbook.
- **Resilience**: 2 replicas for the components whose outage blocks the cluster; etcd CPU request 500m and a
  defragmentation (database 210 → 60 MB; latency came from CPU contention, not the disk); kubelet `maxPods` 110 → 200.

The full history is `git log`.

## Known limits

| Limit | Impact | Plan |
|-------|--------|------|
| One node | the node is a single point of failure | accepted for a lab |
| One SATA SSD (Kingston A400, DRAM-less, 79% life left) for everything | a dead disk loses what is not in R2 | replace it eventually |
| Vault in file mode | no HA, restore through Velero | move to Raft when there are more nodes |
| Alertmanager without receiver | alerts are only seen in Grafana | on purpose while the lab is built |
| DefectDojo without SSO | local accounts | SSO is DefectDojo Pro-only since 3.0 |
| Services only on the home network | no access from outside without a VPN | on purpose |
| Pods per node | the kubelet allows 200 Pods (raised from 110 on 2026-11-15, when CronJobs stopped being scheduled) | watch it; an alert on Pods vs capacity is worth adding |

## Backlog (decided, not started)

| Item | Notes |
|------|-------|
| Right-size the resource requests | Done on 2026-11-16 (c7bf78d, 76dce06) from p95 CPU / max working set since 2026-11-14: requests 86 % → 53 % CPU, 86 % → 69 % memory (with the nvidia prune); limits unchanged. kyverno-reports-controller's ~590m p95 is the hourly background scan, not a fault (request 50m). Left: re-check with 7 days of data (~2026-11-21); aigent-squad-dev (llama-cpu 500m/2Gi, supervisor, gateway) belongs to its own repo. |
| VPS after the cutover (ADR 0008) | Done 2026-11-16: Alloy scrapes in the k8s01 shape (job kubelet + metrics_path, node-exporter, kube-state-metrics with honor_labels; ~8k series) and ships pod/host logs; OTLP goes to the otel-agent again (10.43.100.40). Beyla/eBPF tried and turned off (eBPF maps ~190Mi of kernel memory OOM-killed Alloy on the 8 GB host). MCP servers see the VPS (context vps); image bumps by Renovate PRs (own orgs only). Off by default, ready: Alertmanager → OpenClaw /hooks/alertmanager (alerting.openclaw + openclaw-raw hooksIngress). Trial running: Argo CD Image Updater on the sandbox app image-updater-demo (remove: Application file, platform element, apps _sandbox/, deploy key). Left: Docker removal on the host (on hold by the owner); NET_BIND_SERVICE on mentoria (its image may keep the caddy file capability); openclaw-poller tag `sha-…` is not comparable by Renovate; center and docs to k8s01 later. |
| Per-user OAuth for the MCP servers | Pre-registered public Keycloak client for Claude Code (PKCE, no dynamic registration), Gateway `mcp` advertising `/.well-known/oauth-protected-resource`, access by `/mcp/*` groups. Hermes and Backstage stay on client credentials. |
| Security integrations | Harbor (Trivy) and Dependency-Track findings into DefectDojo; Harbor image push → Argo Events → workflow. Design still open. |
| First workload app | in `homelab-gitops-apps` (candidates: aigent-squad, maturity-scorecard, anomaly-detection) |
| Vault on Raft | when there are more nodes |
| New SSD | see known limits |

## Manual items for the operator

- Keep the R2 API token (access key, secret, endpoint) in the password manager next to `vault-init.json`
  ([disaster-recovery.md](runbooks/disaster-recovery.md), step 0).
