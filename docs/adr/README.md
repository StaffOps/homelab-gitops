# Architecture Decision Records

Short records of decisions that shape this repository (MADR-style: context, decision, consequences).
New ADR: copy the newest one, next number, status `Accepted` once merged. Superseding an ADR: new ADR +
`Superseded by NNNN` in the old one.

| # | Decision | Status |
|---|----------|--------|
| [0001](0001-k3s-single-node.md) | k3s on one node, Traefik and ServiceLB replaced | Superseded by 0006 |
| [0002](0002-self-managed-argo-cd-applicationset.md) | Self-managed Argo CD + ApplicationSet with an explicit app list | Accepted |
| [0003](0003-gateway-api-istio-ambient.md) | Gateway API on Istio ambient instead of ingress-nginx | Accepted |
| [0004](0004-cloudflare-dns.md) | Cloudflare for DNS records and DNS-01 | Accepted |
| [0005](0005-vault-in-cluster.md) | Vault in the cluster as the only secret source | Accepted |
| [0006](0006-kubeadm-calico.md) | Upstream Kubernetes (kubeadm) with Calico instead of k3s | Accepted |
| [0007](0007-separate-apps-repository.md) | Workload apps in a separate repository (homelab-gitops-apps) | Accepted |
