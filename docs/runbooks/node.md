# Node k8s01

## What this is about

Facts about the single node and the cluster, and the few node-level procedures: the kube context on the Mac, kubelet
certificates and a reboot. Host changes (packages, kernel, kubeadm, Calico) live in the Ansible repository
`homelab-ansible`, not here.

## When to use it

- `kubectl --context k8s01` fails with certificate errors, or the context is missing.
- metrics-server reports x509 errors.
- You need to reboot the node.
- You need a network range or a node fact.

## Before you start

- SSH access to `karlipegomes@192.168.68.104` (for the kube context).
- `kubectl` and `yq` on the Mac.

## Node facts

| Fact | Value |
|------|-------|
| Node | `k8s01`, `192.168.68.104` (DNS `k8s01.staffops.space`) |
| OS | Ubuntu 24.04, kernel 6.8 GA (the HWE 7.0 kernel breaks the legacy NVIDIA 470 driver the GT 740 needs) |
| Kubernetes | upstream kubeadm v1.37, containerd, kube-proxy in iptables mode |
| CNI | Calico (VXLAN, via tigera-operator) |
| Mesh | Istio [ambient mode](../glossary.md) on every namespace except `kube-*`, `istio-system`, `calico-system`, `tigera-operator` |

| Network | CIDR |
|---------|------|
| Pods (Calico IPPool) | `10.244.0.0/16` |
| Services | `10.96.0.0/12` |
| MetalLB pool (LAN) | `192.168.68.240-192.168.68.245` |
| API server | `https://192.168.68.104:6443` |

### What kubeadm does not ship, and who brings it

| Missing in kubeadm | Brought by |
|--------------------|------------|
| StorageClass | `helm-charts/local-path-provisioner` (default class `local-path`) |
| Resource metrics API | `helm-charts/metrics-server` |
| Gateway API CRDs | `./bootstrap.sh apply` |
| LoadBalancer | `helm-charts/metallb` |
| Ingress | none: Gateway `public` (Istio) |

The control-plane taint is removed by Ansible (single node); `bootstrap.sh` refuses to apply while it is there. More
context: [architecture.md](../architecture.md).

## Procedures

### Recreate the kube context on the Mac

The context is named `k8s01` (cluster, user and context). It is merged into `~/.kube/config` without changing the
current context. After a cluster rebuild the old entry has stale credentials: recreate it.

```bash
cp ~/.kube/config ~/.kube/config.bak-$(date +%Y%m%d%H%M%S)
kubectl config delete-context k8s01; kubectl config delete-cluster k8s01; kubectl config delete-user k8s01
ssh karlipegomes@192.168.68.104 'sudo cat /etc/kubernetes/admin.conf' > /tmp/k8s01.yaml
yq -i '.clusters[0].name="k8s01" | .users[0].name="k8s01" | .contexts[0].name="k8s01"
       | .contexts[0].context.cluster="k8s01" | .contexts[0].context.user="k8s01" | del(.current-context)' /tmp/k8s01.yaml
KUBECONFIG=~/.kube/config:/tmp/k8s01.yaml kubectl config view --flatten > /tmp/merged && mv /tmp/merged ~/.kube/config
chmod 600 ~/.kube/config && rm /tmp/k8s01.yaml
kubectl --context k8s01 get nodes
```

Expect: `k8s01` Ready. Your current context is unchanged.

> **Note:** `/tmp/k8s01.yaml` holds admin credentials until the last line deletes it.

### kubectl fails with certificate errors

The kubeadm admin certificate lasts a year. `kubeadm certs renew` (or a control-plane upgrade) renews it, through
`homelab-ansible`. Then [recreate the kube context](#recreate-the-kube-context-on-the-mac).

Expect: `kubectl --context k8s01 get nodes` works.

### metrics-server reports x509 errors

The kubelet runs with `serverTLSBootstrap: true`: its serving certificate is signed by the cluster CA, so
metrics-server verifies it (no `--kubelet-insecure-tls`). Ansible approves the first CSR; renewals (about once a year)
are approved by `helm-charts/kubelet-csr-approver` (node name `^k8s01$`, IP in `192.168.68.0/24`).

Look for pending CSRs:

```bash
kubectl --context k8s01 get csr | grep -i pending
```

Expect: nothing pending. If a CSR stays pending, check the `kubelet-csr-approver` app in Argo CD.

### Reboot the node

Everything comes back by itself. Vault starts sealed and the CronJob `vault-autounseal` unseals it within
5 minutes ([vault.md](vault.md#vault-is-sealed)).

Expect: after the reboot, `kubectl --context k8s01 get nodes` shows Ready and `scripts/vault.sh status` shows
`Sealed: false`.

## Check

```bash
kubectl --context k8s01 get nodes -o wide
kubectl --context k8s01 top nodes
```

## If it goes wrong

- Vault still sealed after 5 minutes: [vault.md](vault.md#vault-is-sealed).
- Node NotReady after a reboot, or a host-level problem: fix it through `homelab-ansible`.
