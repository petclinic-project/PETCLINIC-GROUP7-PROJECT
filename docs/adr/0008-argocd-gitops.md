# ADR-0008: ArgoCD for GitOps CD

**Status:** Accepted
**Date:** 2025

---

## Context

CD options evaluated:
- **Push-based:** CI pipeline runs `kubectl apply` directly — simple but requires
  cluster credentials in CI, no drift detection, no audit trail
- **Pull-based GitOps (ArgoCD):** ArgoCD watches Git repo and syncs cluster to
  desired state — more complex setup but production-correct pattern

---

## Decision

ArgoCD for all CD. GitHub Actions is CI-only (build, scan, push images, commit
image tags). ArgoCD watches Git and syncs.

---

## How It Works

CI pushes image → updates helm-values/dev/{service}.yaml in Git
   ↓
ArgoCD polls Git every 3 minutes
   ↓
Detects drift (cluster ≠ Git)
   ↓
Dev: auto-sync immediately
Prod: shows OutOfSync → manual Sync in UI

---

## Consequences

- **Git is the source of truth** — every cluster state change is a Git commit
- **Dev auto-sync:** `selfHeal: true` — if someone manually scales down a pod,
  ArgoCD restores it within 3 minutes. Disable before manual operations:
```bash
  kubectl patch application vets-service-dev -n argocd \
    --type merge -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false}}}}'
```
- **Prod manual sync:** No auto-sync, no selfHeal — explicit operator approval
  required. ArgoCD shows `OutOfSync` but never deploys automatically.
- **No cluster credentials in CI** — CI never runs `kubectl`. Only ArgoCD
  has cluster access.
- **Rollback = git revert** → ArgoCD syncs previous state automatically (dev)
  or on next manual sync (prod)
- **helm-values separation:** CI pipeline only writes to `helm-values/dev/`.
  Prod tags require explicit manual promotion via `promote-to-prod.sh` or
  direct `yq` + git commit. This enforces the dev→prod promotion gate at the
  Git level, not just at the ArgoCD level.
- **ArgoCD RBAC:** Admin has full access. Developer role can view all apps
  but only sync dev apps — cannot touch prod.
