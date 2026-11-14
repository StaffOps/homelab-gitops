# 0001 — k3s on one node, Traefik and ServiceLB replaced

- Status: Superseded by [0006](0006-kubeadm-calico.md)
- Date: 2026-11-13

## Context

The lab first ran minikube with `--driver=none`, which needs cri-dockerd and extra host setup that the install
script never did. The node is a single physical machine on the home LAN.

## Decision

Run k3s (installed and configured by Ansible on the host). Keep its CoreDNS, `local-path` StorageClass,
metrics-server and Gateway API CRDs. Disable its Traefik and ServiceLB: the shared Istio Gateway owns ports
80/443 (ADR 0003) and MetalLB assigns LAN IPs from a dedicated pool.

## Consequences

- One node: no replication; data on `local-path` lives on the node disk (back it up if it matters).
- No PodDisruptionBudgets and 1 replica everywhere.
- `bootstrap.sh` refuses to apply while Traefik or ServiceLB run; `host/k3s-config.yaml` is the reference.
- The kube context must be explicit (`k8s01`): the operator's kubeconfig holds other clusters.
