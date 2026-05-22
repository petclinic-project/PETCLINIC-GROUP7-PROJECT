# ADR-0004: Plain K8s YAML over Helm (Superseded)

**Status:** Superseded by ADR-0007
**Date:** 2025-01-01
**Superseded by:** [ADR-0007](0007-helm-over-plain-yaml.md)

---

## Context

During initial platform design, the team evaluated two approaches for packaging
and deploying the 8 Spring Boot services to Kubernetes:

1. **Plain YAML + Kustomize** — raw Kubernetes manifests with Kustomize overlays
   for environment differences (dev vs prod)
2. **Helm** — templated charts with values files per environment

The initial design chose plain YAML for transparency and simplicity — no
templating engine, no additional abstraction layer, every manifest readable
as-is.

---

## Decision (Original)

Use raw Kubernetes manifests with Kustomize overlays for environment differences.

**Rationale at the time:**
- Plain YAML is easier to read and understand for beginners
- No Helm learning curve
- Kustomize is built into `kubectl` — no additional tool needed
- Full visibility into every generated resource

---

## Why This Was Reversed

After implementing the first version with plain YAML, several problems emerged:

**1. Massive duplication across 8 services**
Each service needed its own `deployment.yaml`, `service.yaml`, `configmap.yaml`.
8 services × 3 files = 24 files with ~90% identical content. Any change to
the deployment template (e.g. adding an init container) required updating all
8 files manually.

**2. Environment differences were awkward with Kustomize**
Kustomize patches work well for small differences but became complex when
dev and prod needed significantly different configurations (replicas, resources,
HikariCP pool size, DB init mode). The patch files were harder to read than
a simple `values.yaml`.

**3. ArgoCD works better with Helm**
ArgoCD has first-class Helm support — it renders the chart, compares the
output to the cluster state, and shows a clean diff in the UI. With plain
YAML + Kustomize, the ArgoCD diff was harder to read and the tooling was
less integrated.

**4. Industry relevance**
Helm is the de facto standard for Kubernetes application packaging. Using Helm
makes the project more representative of real-world practice.

---

## Outcome

A single generic Helm chart was created at `helm/petclinic-service` that serves
all 8 services. Per-service configuration is provided via values files:

```
helm-values/
├── dev/
│   └── {service}.yaml    # ECR dev URL, dev RDS endpoint, image tag
├── prod/
│   └── {service}.yaml    # ECR prod URL, prod RDS endpoint, image tag
├── dev.yaml              # Dev-wide: replicaCount=1, smaller resources
└── prod.yaml             # Prod-wide: replicaCount=2, HikariCP pool=5
```

This reduced 24 near-identical YAML files to 1 chart + 18 small values files.
See ADR-0007 for the full decision rationale.

---

## Lessons Learned

- Plain YAML is good for learning but does not scale beyond 2-3 services
- The "simplicity" of plain YAML disappears quickly when managing 8 identical deployments
- Kustomize and Helm both solve the same problem — Helm is better supported by the ecosystem
- Start with Helm from day one for any project with multiple similar services
