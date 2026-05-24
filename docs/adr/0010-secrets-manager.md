# ADR-0010: AWS Secrets Manager for Secrets Storage

**Status:** Accepted
**Date:** 2025

---

## Context

Application secrets (RDS credentials, OpenAI API key, Grafana password,
Alertmanager Gmail credentials) need secure storage. Options evaluated:
Kubernetes Secrets (base64-encoded, not encrypted at rest by default),
SSM Parameter Store (simpler, cheaper), or AWS Secrets Manager.

---

## Decision

AWS Secrets Manager + External Secrets Operator (ESO) to sync secrets into
Kubernetes as native K8s Secrets.

---

## Secrets Inventory

| Secret ID | Contents | Consumer |
|-----------|----------|----------|
| `petclinic/{env}/rds-credentials` | MySQL username + password | customers, visits, vets |
| `petclinic/{env}/openai-api-key` | OpenAI API key | genai-service |
| `petclinic/{env}/grafana-admin` | Grafana admin password | Grafana |
| `petclinic/{env}/alertmanager-email` | Gmail + app password | Alertmanager |

---

## Consequences

- **Encrypted at rest** with KMS `aws/secretsmanager` key
- **Full audit trail** via CloudTrail — every `GetSecretValue` call is logged
- **ESO sync:** `ClusterSecretStore` with IRSA syncs Secrets Manager →
  Kubernetes Secrets on a schedule (1 hour). Force immediate sync:
```bash
  kubectl annotate externalsecret rds-credentials \
    force-sync=$(date +%s) -n petclinic-dev --overwrite
```
- **No secrets in Git** — `helm-values/` and `k8s/` contain only placeholder
  references, never actual values
- **Alertmanager credentials special handling:** Gmail app passwords contain
  spaces (e.g. `kyxc auvf mqvy dmvs`). Shell `tr -d ' '` strips these spaces,
  causing SMTP authentication failures. `setup-cluster.sh` uses Python to read
  and inject the secret, preserving spaces. This is documented as a known
  gotcha — never use shell string manipulation for the alertmanager password.
- **Secrets Manager vs SSM Parameter Store:** Secrets Manager costs $0.40/secret/month
  vs SSM free tier for standard parameters. We chose Secrets Manager for automatic
  rotation support, better ESO integration, and production correctness.
- **Cost:** $0.40/secret/month × 4 secrets × 2 environments = ~$3.20/month
