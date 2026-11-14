# 0004 — Cloudflare for DNS records and DNS-01

- Status: Accepted
- Date: 2026-11-13

## Context

The domain `staffops.space` is registered at Hostinger. Neither external-dns nor cert-manager supports
Hostinger's DNS API (only community webhooks would). The previous setup used Google Cloud DNS with a GCP
service account, a dependency on a cloud project for a home lab.

## Decision

Delegate the zone to Cloudflare (registration stays at Hostinger, nameservers point to Cloudflare). One
Cloudflare API token (Zone:DNS:Edit, scoped to this zone) stored in Vault `homelab/cloudflare` serves:

- external-dns: provider `cloudflare`, source `gateway-httproute`, `txtOwnerId: k8s01`, never proxied;
- cert-manager: ClusterIssuers `letsencrypt-prod` / `letsencrypt-staging`, DNS-01 solver `cloudflare`,
  propagation checked on public resolvers.

## Consequences

- Records are public but point to private LAN addresses; nothing is reachable from outside the LAN.
- The zone is shared with hosts outside the cluster. Their records are imported once from a zone file kept
  outside the repository (`scripts/cloudflare-setup.sh`); external-dns only deletes records it owns (TXT
  registry), so it never touches them. `grafana` and `prometheus` moved from the VPS to the cluster.
- Changing nameservers at Hostinger is a one-time manual step (runbooks/first-install.md).
- No GCP dependency is left in the repository.
