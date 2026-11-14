# First install (or full rebuild)

Order matters only for secrets: apps that need one keep retrying until Vault has it.

## 0. Once per domain: Cloudflare

Other hosts (the VPS) also use `staffops.space`: their records must be on Cloudflare **before** the
nameservers move. They live in a BIND file outside the repository, `~/.config/homelab/staffops.space.zone`
(the lab's own records are not there: external-dns creates them).

1. Cloudflare → My Profile → API Tokens → Create Custom Token (bootstrap, temporary): Account Settings Read,
   Zone Edit, DNS Edit, User API Tokens Edit.
2. `scripts/cloudflare-setup.sh setup` — creates the zone, imports the zone file (fails if any record is
   missing), mints the cluster token into `~/.config/homelab/cloudflare-api-token` and prints the nameservers.
3. Check the imported records in the Cloudflare dashboard, then at Hostinger (domain → Nameservers) set the
   two Cloudflare nameservers.
4. `scripts/cloudflare-setup.sh status` until `active` (minutes to hours). Delete the bootstrap token.
5. The cluster token goes to Vault in step 4 below.

## 1. Host

kubeadm cluster up from `homelab-ansible` (node Ready with Calico, control-plane taint removed) and the kube
context `k8s01` on the Mac ([node.md](node.md)).

## 2. Repository layout on `main`

Argo CD syncs `origin/main`, not the local checkout: push the layout before bootstrapping.

## 3. Bootstrap

```bash
./bootstrap.sh diff     # read the checks; nothing is applied
./bootstrap.sh apply    # Gateway API + prometheus-operator CRDs, Argo CD, root Application
./bootstrap.sh status   # wait until the ApplicationSet created the platform Applications
```

`local-path-provisioner`, `metrics-server`, `kubelet-csr-approver`, `metallb`, `vault` and `istio` sync on their own (Vault's
volume binds once the StorageClass exists). `cert-manager`, `external-dns`, `monitoring`, `keycloak`, `dependency-track` and `velero`
stay degraded until their secrets exist (step 4) — expected.

## 4. Vault

```bash
scripts/vault.sh init                                   # saves ~/.config/homelab/vault-init.json — copy it offline now
scripts/vault.sh configure                              # KV v2, Kubernetes auth, role external-secrets
scripts/vault.sh put cloudflare api-token
scripts/vault.sh put grafana admin-user admin-password
scripts/vault.sh put keycloak admin-user admin-password
scripts/vault.sh put oidc argocd grafana vault      # random client secrets
scripts/vault.sh put dependency-track kek            # openssl rand -base64 32
scripts/vault.sh put velero access-key-id secret-access-key endpoint   # R2 token, runbooks/backup.md
```

External Secrets picks the values up within an hour; to speed it up force a sync
([vault.md](vault.md#force-a-refresh)).

## 5. Check

```bash
kubectl --context k8s01 get clustersecretstore vault                 # Ready=True
kubectl --context k8s01 get externalsecrets -A                       # all SecretSynced
kubectl --context k8s01 -n gateway get certificate wildcard          # Ready=True (DNS-01 can take ~2 min)
kubectl --context k8s01 -n gateway get gateway public                # address 192.168.68.240, Programmed
dig +short argocd.staffops.space                                     # 192.168.68.240
```

Then `https://argocd.staffops.space` (user `admin`, password in `argocd-initial-admin-secret`; change it and
delete that Secret).

## 6. Single sign-on

Once `keycloak` is Healthy: [sso.md](sso.md#first-time) (Keycloak admin and user, `scripts/vault.sh oidc`).
