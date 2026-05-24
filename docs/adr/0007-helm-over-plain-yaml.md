# ADR-0007: Helm over Plain K8s YAML (Supersedes ADR-0004)

**Status:** Accepted
**Date:** 2025-01-15
**Supersedes:** [ADR-0004](0004-plain-yaml-over-helm.md)

---

## Context

After initially using plain Kubernetes YAML + Kustomize (ADR-0004), the
following problems emerged as the project grew to 8 services across 2
environments:

- 8 services × 2 environments = 16 near-identical manifest sets
- Any structural change (e.g. adding an init container, changing a label)
  required editing all 16 sets manually
- Kustomize patches became complex for environment differences beyond
  simple image tag changes
- No standard way to share configuration between services of the same type
- ArgoCD diff view was cluttered with Kustomize-generated resources

A better packaging approach was needed that would scale to 8+ services
without maintenance overhead.

---

## Decision

Use a **single generic Helm chart** (`helm/petclinic-service/`) shared by all
8 services. Per-service and per-environment configuration is provided via
separate values files.

**Chart structure:**
```
helm/petclinic-service/
├── Chart.yaml
├── values.yaml          # Base defaults
└── templates/
├── _helpers.tpl     # Shared helper functions
├── deployment.yaml  # Parameterized deployment
├── service.yaml     # Parameterized service
├── configmap.yaml   # Optional configmap
├── hpa.yaml         # Optional HPA (prod only)
├── pdb.yaml         # Optional PDB (prod only)
└── serviceaccount.yaml
```

**Values file structure:**

```
helm-values/
├── dev/
│   └── {service}.yaml   # ECR dev URL, dev RDS endpoint, image tag, env vars
├── prod/
│   └── {service}.yaml   # ECR prod URL, prod RDS endpoint, image tag, env vars
├── dev.yaml             # Dev-wide: replicaCount=1, smaller resources
└── prod.yaml            # Prod-wide: replicaCount=2, HikariCP pool=5
```

**Value loading order in ArgoCD (later overrides earlier):**

```
chart defaults (values.yaml)
     ↓
service-specific (helm-values/{env}/{service}.yaml)
     ↓
environment-wide (helm-values/{env}.yaml)
```
---

## Why Helm over Kustomize

| Concern | Kustomize | Helm |
|---------|-----------|------|
| Template reuse across services | Bases + patches (verbose) | Single chart (clean) |
| Environment differences | Patch files per env | Values files per env |
| Conditional resources (HPA, PDB) | Separate overlays | `{{ if .Values.hpa.enabled }}` |
| ArgoCD integration | Supported | First-class native support |
| Industry adoption | Growing | De facto standard |
| Diff readability in ArgoCD | Moderate | Excellent |

---

## helm-values Separation (dev/ and prod/)

An important implementation detail: helm-values are separated into
`dev/` and `prod/` subdirectories rather than a flat structure.

**Why this matters:**

1. **CI/CD isolation** — the CI pipeline (`update-image-tags.yml`) only
   writes to `helm-values/dev/`. Prod tags are never updated automatically.
   With a flat structure, the pipeline would need extra logic to avoid
   accidentally updating prod values.

2. **generate-config.sh isolation** — when running `generate-config.sh dev`,
   only `helm-values/dev/` is updated. Running `generate-config.sh prod`
   only updates `helm-values/prod/`. No cross-contamination between environments.

3. **Clarity** — looking at `helm-values/prod/vets-service.yaml` immediately
   tells you the prod image tag. With a flat structure and environment
   overrides, you would need to mentally merge multiple files.

4. **GitOps auditability** — a Git diff on `helm-values/prod/` shows exactly
   what changed in prod. A diff on `helm-values/dev/` shows dev changes.
   No mixing.

---

## Consequences

**Positive:**
- Single chart template maintains consistency across all 8 services
- Adding a new service requires only a new values file — no new templates
- ArgoCD natively renders Helm charts and shows clean diffs
- Conditional features (HPA, PDB, init containers) controlled via values
- `helm-values/dev/` and `helm-values/prod/` are cleanly separated
- CI/CD pipeline only touches `helm-values/dev/` — prod requires explicit
  manual promotion

**Negative:**
- Helm templating syntax is less transparent than raw YAML for beginners
- Debugging requires `helm template` to see rendered output:
```bash
  helm template vets-service helm/petclinic-service \
    -f helm-values/dev/vets-service.yaml \
    -f helm-values/dev.yaml
```
- Helm chart changes affect all 8 services simultaneously — test carefully
  before committing chart template changes

---

## Alternatives Considered

**Helm + Kustomize together:** ArgoCD supports both but mixing them adds
complexity. Rejected — one tool is sufficient.

**Separate chart per service:** Maximum flexibility but defeats the purpose
of code reuse. Rejected — 8 charts with ~90% identical content is the same
problem as 8 YAML directories.

**Helmfile:** Declarative Helm release management. Would work but adds
another tool. ArgoCD already provides the orchestration layer. Rejected.


