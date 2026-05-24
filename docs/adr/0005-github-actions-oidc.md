# ADR-0005: GitHub Actions with OIDC Federation

**Status:** Accepted
**Date:** 2025

---

## Context

CI pipelines need AWS credentials to push images to ECR and update infra repo.
Options: long-lived IAM access keys stored as GitHub Secrets, or short-lived
credentials via OIDC federation.

Long-lived keys are a security risk — they never expire, must be rotated
manually, and if leaked give permanent AWS access.

---

## Decision

Use OIDC federation — no long-lived credentials. GitHub Actions generates a
short-lived JWT per workflow run. AWS exchanges it for temporary STS credentials
scoped to the specific IAM role.

---

## Consequences

- **No static credentials to rotate or leak** — credentials expire after the
  workflow run completes
- **Trust policy scoped to main branch:** `ref:refs/heads/main` of the app repo only
  — feature branches cannot assume the role
- **Single shared role for dev and prod ECR:** `petclinic-github-actions-role`
  uses wildcard policy `petclinic-*/*` to cover both `petclinic-dev/*` and
  `petclinic-prod/*` repos. This allows the CI pipeline to push to dev and the
  promotion script to push to prod without separate roles.
- **PLATFORM_REPO_TOKEN:** A separate fine-grained GitHub PAT is needed for the
  infra repo write operation (`update-image-tags.yml` commits new tags). OIDC
  only covers AWS — GitHub API calls use the PAT. The PAT is scoped to
  `petclinic-infra` repo with Contents:write only.
- **AWS-recommended pattern** for CI/CD — documented in AWS security best practices
- **pre-apply-check.sh import:** The OIDC provider (`oidc.eks.amazonaws.com/id/*`)
  is created by dev Terraform and shared with prod. `pre-apply-check.sh`
  imports the existing OIDC provider into prod state to prevent conflict.
