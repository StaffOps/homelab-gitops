# 0005 — Vault in the cluster as the only secret source

- Status: Accepted
- Date: 2026-11-13

## Context

Secrets came from GCP Secret Manager through External Secrets and `vals` (`ref+gcpsecrets://`), which tied
the lab to a cloud project and needed a long-lived service account key on the cluster.

## Decision

- HashiCorp Vault (chart `hashicorp/vault`, standalone, file storage on `local-path`, injector off) runs in
  namespace `vault`, deployed by Argo CD like any app.
- External Secrets reads KV v2 `secret/homelab/*` through `ClusterSecretStore vault` with Kubernetes auth
  (role `external-secrets`, read-only policy). Apps only declare ExternalSecrets.
- Argo CD renders nothing secret: the repository is public and Redis is internal, so the bootstrap needs no
  secret at all.
- Init/unseal/configure are manual and scripted (`scripts/vault.sh`), with 1 key share; keys stay outside the
  repository.

## Consequences

- Vault starts sealed after every pod restart (node reboot included) until `scripts/vault.sh unseal` runs;
  `VaultSealed` alerts. Auto-unseal would need an external KMS or a second Vault — not worth it for one node.
- Losing `vault-init.json` and the Vault volume together loses every secret: keep an offline copy of the init
  file; secret values should also exist in the operator's password manager.
- Vault is BUSL-licensed; OpenBao is a drop-in alternative if that matters later.
