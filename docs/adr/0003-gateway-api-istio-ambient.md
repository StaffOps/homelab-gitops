# 0003 — Gateway API on Istio ambient instead of ingress-nginx

- Status: Accepted
- Date: 2026-11-13

## Context

The lab exposed apps with ingress-nginx, which the Kubernetes project retired in March 2026 (no further
releases or security fixes). Istio ambient was already installed for the mesh and implements the Gateway API
(CRDs installed by `bootstrap.sh`).

## Decision

- One shared Gateway `public` (namespace `gateway`, class `istio`) on the fixed MetalLB IP `192.168.68.240`,
  listeners `http` (redirect only) and `https` (wildcard certificate `*.staffops.space`).
- Apps expose themselves with an HTTPRoute to `sectionName: https`; no Ingress, no per-app LoadBalancer.
- Istio is installed with `profile=ambient`; istio-cni chains onto Calico (ADR 0006).

## Consequences

- One IP and one certificate for every app; external-dns reads the HTTPRoutes (ADR 0004).
- Charts without HTTPRoute support get the route from the app's `-raw` release.
- ingress-nginx and its NGINX-specific annotations are gone.
