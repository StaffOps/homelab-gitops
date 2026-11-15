# Glossary

Short definitions of the words used in this documentation, in the sense they have **in this lab**.

| Term | Meaning here |
|------|--------------|
| **Ambient mode** | Istio's sidecar-less mesh. A namespace joins with the label `istio.io/dataplane-mode=ambient` (added by Kyverno). Traffic between its Pods is encrypted by ztunnel. |
| **AppProject** | Argo CD's permission boundary. `platform` may do anything; `apps` may only deploy namespaced objects outside platform namespaces. |
| **ApplicationSet** | An Argo CD template that creates Applications. `platform` reads an explicit list; `apps` creates one Application per directory of the apps repository. |
| **Barman Cloud** | The CloudNativePG plugin that sends PostgreSQL base backups and WAL to R2. |
| **Break-glass account** | A local admin kept for when Keycloak is down: Grafana, Harbor, Dependency-Track and DefectDojo (passwords in Vault), Argo CD (`argocd-initial-admin-secret`), Vault (root token in `vault-init.json`). |
| **CloudNativePG (CNPG)** | The operator that runs PostgreSQL from a `Cluster` resource: one per app that needs a database. |
| **ClusterSecretStore / SecretStore** | Where External Secrets reads from. The cluster-wide `vault` store serves platform namespaces; each app namespace has its own `vault` SecretStore limited to its path. |
| **CRD** | Custom Resource Definition: a new object type (Certificate, Cluster, Rollout...) added by an operator. |
| **ExternalSecret** | A Kubernetes object that says "copy key X from Vault into Secret Y". The Secret is created and refreshed by External Secrets. |
| **Gateway / HTTPRoute** | Kubernetes Gateway API. The Gateway is the entry point (`192.168.68.240`); each app's HTTPRoute maps a hostname to its Service. |
| **HBONE** | The tunnel protocol of Istio ambient (TCP port 15008). NetworkPolicies in mesh namespaces must allow it. |
| **helmfile** | A tool that renders several Helm charts with shared values. Every app here is a helmfile directory; Argo CD renders it with a plugin. |
| **Hook (Argo CD)** | A Job or Workflow that Argo CD runs before or after a sync (e.g. the Keycloak realm import, the DefectDojo initializer). |
| **Kyverno** | Policy engine: audits Pod security, labels Pods and namespaces automatically. |
| **MCP server** | A Model Context Protocol server: lets an AI agent (Claude Code, Hermes) query a tool (Kubernetes, Grafana, Argo CD...) read-only. |
| **MetalLB** | Gives LoadBalancer Services an IP of the home LAN (`192.168.68.240-245`). |
| **Mixin** | A package of dashboards and alert rules published by a project (kubernetes-mixin, etcd mixin...). Alert rules here come from mixins or official docs. |
| **OBI** | OpenTelemetry eBPF Instrumentation: traces HTTP/gRPC/SQL calls of apps without code changes. |
| **OTLP** | The OpenTelemetry protocol for metrics, logs and traces. |
| **PDB** | PodDisruptionBudget: limits voluntary evictions (like `kubectl drain`). Not used here, because on one node it would block drains. |
| **PodMonitor / ServiceMonitor** | Tell Prometheus which Pods or Services to scrape. |
| **R2** | Cloudflare's S3-compatible object storage. Holds the backups (Velero and CloudNativePG). |
| **Render** | Turning a helmfile directory into Kubernetes YAML. `scripts/render-app.sh <app>` does it locally, like Argo CD. |
| **selfHeal / prune** | Argo CD settings: revert manual changes in the cluster / delete objects removed from Git. Both are on. |
| **Unseal** | Vault starts locked (sealed) after a restart. Unsealing it needs the key in `vault-init.json`; the CronJob `vault-autounseal` does it automatically. |
| **WAL** | PostgreSQL's write-ahead log. Archived continuously to R2, it allows restoring a database to any point in time. |
| **ztunnel** | The Istio ambient node proxy (one per node) that carries and encrypts the mesh traffic. |
