# Node k8s01

Node: `k8s01`, `192.168.68.104` (DNS `k8s01.staffops.space`), Ubuntu 24.04, kernel 6.8 GA (the HWE 7.0
kernel breaks the legacy NVIDIA 470 driver the GT 740 needs). Kubernetes is upstream kubeadm v1.37 with
containerd, Calico (VXLAN, via tigera-operator) and kube-proxy in iptables mode, all installed and configured
by the Ansible repository `homelab-ansible` — host changes go there, not here.

| Network | CIDR |
|---------|------|
| Pods (Calico IPPool) | `10.244.0.0/16` |
| Services | `10.96.0.0/12` |
| MetalLB pool (LAN) | `192.168.68.240-192.168.68.245` |
| API server | `https://192.168.68.104:6443` |

## What the cluster does not ship (and who brings it)

| Missing in kubeadm | Brought by |
|--------------------|------------|
| StorageClass | `helm-charts/local-path-provisioner` (default class `local-path`) |
| Resource metrics API | `helm-charts/metrics-server` |
| Gateway API CRDs | `./bootstrap.sh apply` |
| LoadBalancer | `helm-charts/metallb` |
| Ingress | none: Gateway `public` (Istio) |

The control-plane taint is removed by Ansible (single node); `bootstrap.sh` refuses to apply while it is there.

## Kube context on the Mac

The context is named `k8s01` (cluster, user and context). It is merged into `~/.kube/config` without changing
the current context. After a cluster rebuild the old entry has stale credentials: recreate it.

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

The kubeadm admin certificate lasts a year; `kubeadm certs renew` (or a control-plane upgrade) renews it.
Re-run the above when `kubectl --context k8s01` fails with certificate errors.

## Kubelet serving certificates

The kubelet runs with `serverTLSBootstrap: true`: its serving certificate is signed by the cluster CA, so
metrics-server verifies it (no `--kubelet-insecure-tls`). Ansible approves the first CSR; renewals (about once
a year) are approved by `helm-charts/kubelet-csr-approver` (node name `^k8s01$`, IP in `192.168.68.0/24`).
If metrics-server reports x509 errors, look for pending CSRs:

```bash
kubectl --context k8s01 get csr | grep -i pending
```

## Node reboot

Everything comes back by itself except Vault, which starts sealed: `scripts/vault.sh unseal`
([vault.md](vault.md)).
