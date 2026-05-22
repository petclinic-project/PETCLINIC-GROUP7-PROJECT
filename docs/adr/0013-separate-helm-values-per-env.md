# ADR-0013: Separate helm-values Directories per Environment

**Status:** Accepted
**Date:** 2025

---

## Context

After implementing Helm (ADR-0007), all per-service values files were initially
in a flat `helm-values/` directory:

helm-values/
├── vets-service.yaml      # one file, used by both dev and prod
├── customers-service.yaml
└── ...

Environment differences (image tags, ECR URLs, RDS endpoints) were managed
via ArgoCD application-level value file layering. However, this created
several problems as the project matured.

---

## Decision

Separate helm-values into per-environment subdirectories:

helm-values/
├── dev/
│   └── {service}.yaml    # dev-specific: ECR dev URL, dev tag, dev RDS
├── prod/
│   └── {service}.yaml    # prod-specific: ECR prod URL, prod tag, prod RDS
├── dev.yaml              # dev-wide overrides (replicaCount=1)
└── prod.yaml             # prod-wide overrides (replicaCount=2, HikariCP=5)

---

## Why This Change Was Made

**Problem 1 — CI/CD pipeline contamination risk:**
The CI pipeline (`update-image-tags.yml`) commits new image tags to the
infra repo after a successful build. With a flat structure, the pipeline
would need logic to update only the dev tag and not accidentally update the
prod tag in the same file. With separate directories, the pipeline simply
writes to `helm-values/dev/{service}.yaml` — prod is a different directory
and physically cannot be touched.

**Problem 2 — generate-config.sh contamination:**
`generate-config.sh` injects dynamic values (ECR URLs, RDS endpoints, cert
ARNs) after `terraform apply`. With a flat structure, running
`generate-config.sh dev` would overwrite values that prod needed. Separate
directories mean dev and prod configs are independent.

**Problem 3 — stale root-level files:**
As the project evolved, the root-level `helm-values/{service}.yaml` files
became stale — they existed but weren't used by ArgoCD (which had been
updated to use env-specific paths). This caused confusion about which file
was authoritative. The flat files were deleted as part of this change.

**Problem 4 — GitOps auditability:**
With a flat structure, a `git diff helm-values/` shows changes to both dev
and prod mixed together. With separate directories, `git diff helm-values/prod/`
shows only prod changes — much cleaner for audit and review.

---

## Implementation

Each ArgoCD Application CRD was updated to reference env-specific value files:

```yaml
# argocd/applications/dev/vets-service-dev.yaml
helm:
  valueFiles:
    - ../../helm-values/dev/vets-service.yaml   # was: ../../helm-values/vets-service.yaml
    - ../../helm-values/dev.yaml
```

The CI pipeline was updated to write to `helm-values/dev/`:

```yaml
# .github/workflows/update-image-tags.yml
FILE="helm-values/dev/${SERVICE}.yaml"   # was: helm-values/${SERVICE}.yaml
```

`generate-config.sh` was updated to write to `helm-values/${ENV}/`.

---

## Consequences

**Positive:**
- CI pipeline physically cannot touch prod helm-values
- `generate-config.sh dev` and `generate-config.sh prod` are fully isolated
- Git history per environment is clean and auditable
- Promotes explicit prod promotion — operator must manually update
  `helm-values/prod/{service}.yaml` to deploy to prod
- No stale root-level files causing confusion

**Negative:**
- 8 additional files (16 service files instead of 8)
- ArgoCD Application CRDs had to be updated for all 18 applications
- Minor: slightly more files to manage, but the structure is intuitive

## Alternatives Considered

**Helm `--set` flags per environment:** Pass env-specific values via ArgoCD
`helm.parameters` instead of files. Rejected — parameters are less readable
than files and harder to review in Git diffs.

**Single file with environment conditionals:** One values file using Helm
`{{ if eq .Values.env "prod" }}` blocks. Rejected — mixing env config in
one file defeats the purpose of separation and makes diffs unreadable.
