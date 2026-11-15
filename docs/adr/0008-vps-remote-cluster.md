# 0008 — The VPS k3s as a remote cluster of this Argo CD

- Status: Accepted
- Date: 2026-11-15

## Context

The VPS (`srv1853985`) moves from docker compose to a k3s cluster that runs only applications (authelia, 9router,
openclaw, chaitops, mentoria, edge proxies and collectors). k8s01 is the central node: Argo CD, Vault, Prometheus,
Loki and Grafana stay here. Both hosts are peers in the operator's Tailscale tailnet; the k3s API listens on 6443
only on `tailscale0`. The VPS base has cluster-scoped pieces (CRDs and webhooks of cert-manager and External
Secrets, ClusterRoles of Alloy and kube-state-metrics, a ClusterSecretStore).

## Decision

- Argo CD on k8s01 registers the VPS as cluster `vps` through a declarative cluster Secret
  (`argo-cd-raw/resources/externalsecret-argocd-cluster-vps.yaml`), built by External Secrets from Vault
  `homelab/argocd-cluster-vps` (`token`, `ca-data`). Server `https://100.81.185.50:6443`: the tailnet IP, because
  Pods here cannot resolve MagicDNS names; the IP is in the k3s certificate SANs.
- The ServiceAccount Argo CD uses on the k3s (`kube-system/argocd-manager`, created by the VPS Ansible) is
  **cluster-admin** (operator's decision, 2026-11-15), so all of the VPS, base included, is GitOps.
- Two halves, each with its own AppProject, so the cluster-admin power is only reachable from reviewed commits in
  this repository:
  - **Base** in this repository, `helm-charts/vps/<app>`: ApplicationSet `platform-vps` (explicit list, like
    `platform`), Applications `vps-<appName>`, AppProject `platform-vps` (source this repository, destination the
    vps cluster only, any kind). Namespaces: `cert-manager`, `external-secrets`, `external-dns`, `observability`.
  - **Apps** in [StaffOps/homelab-gitops-apps](https://github.com/StaffOps/homelab-gitops-apps) under
    `vps/<app>/<release>/`, with `vps/environment.yaml` as that cluster's contract (no Istio, no Gateway API:
    Traefik Ingress). ApplicationSet `vps` creates one Application `vps-<release>` per release directory;
    ApplicationSet `apps` skips `vps/`. AppProject `vps`: source the apps repository, destination the vps
    cluster except its system and base namespaces (`remoteClusters.vps.platformNamespaces`), cluster-scoped
    kinds Namespace and PersistentVolume only (the apps keep data in static hostPath PVs).
- The application repositories and their ghcr images stay private. The k3s pulls with a read-only
  (`read:packages`) credential that the VPS Ansible installs in `registries.yaml`; its value never enters git.
- Credentials travel encrypted (GPG to the operator's machine) and are written to Vault from there; they never
  appear in chat, logs or git.

## Consequences

- The apps repository is public: image names, hostnames and the VPS topology are visible (operator's decision).
  Secrets are never there: they come from Vault.
- A leaked `homelab/argocd-cluster-vps` token gives full control of the VPS. It lives only in Vault and is used
  only over the tailnet; rotate it by recreating the token Secret on the k3s and writing Vault again.
- If the tailnet or k8s01 is down, the VPS keeps running; Argo CD only stops syncing it.
- A new base namespace must be added both to ApplicationSet `platform-vps` and to
  `remoteClusters.vps.platformNamespaces`.
- Still to design: External Secrets on the VPS reading this Vault over the tailnet, and Prometheus remote-write
  and Loki push reachable from the tailnet only.
