# ADR-0009: ECR Private Registry

**Status:** Accepted
**Date:** 2025

---

## Context

Container images need a registry. Options evaluated: Docker Hub (public, rate
limits, images publicly visible), GitHub Container Registry (fine but adds
another service), or Amazon ECR Private (native AWS integration).

---

## Decision

Amazon ECR Private with separate repositories per environment.
petclinic-dev/{service}    — dev images, MUTABLE tags
petclinic-prod/{service}   — prod images, IMMUTABLE tags

---

## Consequences

- **IAM-controlled access:** EKS node IAM role has `AmazonEC2ContainerRegistryReadOnly`
  — pods pull images without credentials. CI has push-only access via OIDC.
- **Separate repos per environment:** Dev and prod images are stored separately.
  Prod images are promoted from dev (copied via `docker pull/tag/push`) — not
  rebuilt. This ensures identical binaries in dev and prod.
- **IMMUTABLE prod tags:** Once a SHA tag is pushed to `petclinic-prod/*`, it
  cannot be overwritten. A compromised CI pipeline cannot silently replace a
  running prod image. Dev uses MUTABLE tags (convenient for development).
- **Scan on push:** ECR basic scanning runs on every push. Results visible in
  ECR console. Trivy in CI pipeline provides more detailed scanning with
  artifact upload.
- **Lifecycle policies:** Keep last 10 tagged images, expire untagged after
  7 days. Prevents unbounded storage growth.
- **GitHub Actions wildcard policy:** `petclinic-*/*` covers both dev and prod
  repos with a single IAM policy — no separate roles needed for promotion.
- **Cost:** ~$1/month beyond 500MB free tier per environment
