# 0006 — Upstream Kubernetes (kubeadm) with Calico instead of k3s

- Status: Accepted
- Date: 2026-11-13
- Supersedes: [0001](0001-k3s-single-node.md)

## Context

k3s (ADR 0001) bundles add-ons the platform replaces anyway (Traefik, ServiceLB) and hides the control plane
in one process. The lab is meant to mirror a standard cluster. Cilium was considered as CNI and dropped for
this node: Istio ambient stays, and its CNI chaining is simplest on a plain CNI.

## Decision

Run upstream Kubernetes v1.37 with kubeadm on the single node `k8s01`, containerd 2.2, Calico v3.33 (VXLAN,
no BGP, tigera-operator) and kube-proxy in iptables mode, control-plane taint removed. Ansible
(`homelab-ansible`) owns the host and the cluster up to a Ready node with a CNI. This repository brings
everything above that: local-path-provisioner (default StorageClass `local-path`), metrics-server,
kubelet-csr-approver, MetalLB,
Gateway API CRDs (`bootstrap.sh`), Istio ambient and the rest of the platform.

## Consequences

- One node: no replication; data on `local-path` lives under `/opt/local-path-provisioner` on the node disk, as
  `local` PVs (not hostPath) so Velero can back them up.
- No PodDisruptionBudgets and 1 replica everywhere.
- Istio installs with the default platform (no `global.platform`); istio-cni chains onto Calico.
- kube-prometheus-stack does not scrape controller-manager, scheduler, etcd or kube-proxy: kubeadm binds their
  metrics to 127.0.0.1.
- Kubelet serving certificates are CA-signed (`serverTLSBootstrap`); kubelet-csr-approver approves renewals,
  so metrics-server verifies TLS.
- The kube context must be explicit (`k8s01`): the operator's kubeconfig holds other clusters.
