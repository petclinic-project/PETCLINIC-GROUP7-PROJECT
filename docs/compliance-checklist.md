# Petclinic Platform — Compliance Checklist

---

## Encryption at Rest

| Resource | Status | Key |
|----------|--------|-----|
| RDS MySQL | ✅ Encrypted | AWS default KMS |
| S3 (Terraform state) | ✅ SSE-S3 (AES256) | AWS managed |
| EBS Volumes (nodes, PVCs) | ✅ Default encryption | AWS managed |
| ECR Images | ✅ AES256 | AWS managed |
| Secrets Manager | ✅ KMS | `aws/secretsmanager` |
| Alertmanager credentials | ✅ KMS | Stored in Secrets Manager, never in Git |

---

## Encryption in Transit

| Path | Status | Method |
|------|--------|--------|
| Internet → ALB | ✅ TLS 1.2+ | ACM wildcard cert `*.praty.dev` |
| ALB → Pod | ⚠️ HTTP (internal only) | SSL termination at ALB — pods receive HTTP |
| Pod → RDS | ⚠️ SSL available, not enforced | Configure `spring.datasource.ssl=true` to enforce |
| Pod → Secrets Manager | ✅ HTTPS | AWS SDK default |
| Pod → ECR | ✅ HTTPS | AWS SDK default |
| ArgoCD → GitHub | ✅ HTTPS | Git over HTTPS |

> **Note on internal HTTP:** Pod-to-pod traffic within the VPC is unencrypted.
> This is acceptable for this project as all traffic stays within the private VPC
> and is protected by security groups. For production hardening, enable mTLS via a
> service mesh (e.g. AWS App Mesh or Istio).

---

## IAM Roles Inventory

| Role | Permissions | Scope |
|------|------------|-------|
| `petclinic-{env}-eks-cluster-role` | AmazonEKSClusterPolicy | EKS control plane |
| `petclinic-{env}-eks-node-role` | Worker, CNI, ECR read | EKS nodes + Karpenter nodes |
| `petclinic-{env}-ebs-csi-role` | AmazonEBSCSIDriverPolicy | EBS volumes (PVCs) |
| `petclinic-{env}-lb-controller-role` | ALB management | Load balancers via IRSA |
| `petclinic-{env}-eso-role` | `secretsmanager:GetSecretValue` on `petclinic/*` | ESO secrets sync via IRSA |
| `petclinic-{env}-karpenter-role` | EC2 provisioning, SQS, EKS describe | Karpenter node autoscaling via IRSA |
| `petclinic-github-actions-role` | ECR push to `petclinic-*/*`, ECR auth | CI/CD pipeline via OIDC (shared dev+prod) |

> **OIDC federation:** GitHub Actions uses OIDC — no long-lived AWS keys stored in
> GitHub secrets. The OIDC trust policy restricts to `main` branch of the app repo only.
> `petclinic-github-actions-role` uses wildcard `petclinic-*/*` to cover both dev and
> prod ECR repos with a single shared role.

---

## Access Control

| Area | Control | Status | Notes |
|------|---------|--------|-------|
| EKS cluster | IAM + RBAC | ✅ | `bootstrap_cluster_creator_admin_permissions = false` |
| ArgoCD | RBAC (admin + developer roles) | ✅ | Developer can only sync dev apps |
| Secrets | IAM + ESO IRSA | ✅ | Only ESO service account can read Secrets Manager |
| RDS | Security Group | ✅ | Port 3306 only from EKS node SG |
| ECR | IAM | ✅ | Nodes: read only. CI: push only. |
| S3 state | IAM + public access blocked | ✅ | Versioning enabled for state recovery |
| ALB | Security Group | ✅ | Port 443 open, port 80 redirects to 443 |
| Grafana | Admin password in Secrets Manager | ✅ | Synced via ESO |

---

## Secrets Inventory

| Secret ID | Contents | Used By |
|-----------|----------|---------|
| `petclinic/dev/rds-credentials` | MySQL username + password | customers, visits, vets services |
| `petclinic/prod/rds-credentials` | MySQL username + password | customers, visits, vets services |
| `petclinic/dev/openai-api-key` | OpenAI API key | genai-service |
| `petclinic/prod/openai-api-key` | OpenAI API key | genai-service |
| `petclinic/dev/grafana-admin` | Grafana admin password | Grafana |
| `petclinic/prod/grafana-admin` | Grafana admin password | Grafana |
| `petclinic/dev/alertmanager-email` | Gmail + app password | Alertmanager |
| `petclinic/prod/alertmanager-email` | Gmail + app password | Alertmanager |

> **No secrets in Git.** All credentials flow: Secrets Manager → ESO → K8s Secret → Pod env var.
> Alertmanager credentials injected at deploy time by `setup-cluster.sh` using Python
> (shell `tr -d ' '` strips spaces from Gmail app passwords — Python preserves them).

---

## Audit Logging

| Service | Logging | Retention |
|---------|---------|-----------|
| EKS API | API + audit + authenticator logs → CloudWatch | 90 days |
| AWS API calls | CloudTrail | 90 days default |
| Application logs | Loki via FluentBit | 7 days (dev), 30 days (prod) |
| Secrets access | CloudTrail via Secrets Manager | 90 days |
| ArgoCD sync events | ArgoCD application history | 10 revisions |
| GitHub Actions | GitHub audit log | 90 days |

---

## Data Classification

| Data | Classification | Storage | Protection |
|------|---------------|---------|-----------|
| Pet/owner records | PII (GDPR applicable) | RDS MySQL | Encrypted at rest, access via SG |
| Visit records | PII (GDPR applicable) | RDS MySQL | Encrypted at rest |
| RDS credentials | Secret | Secrets Manager | KMS encrypted, IRSA access only |
| OpenAI API key | Secret | Secrets Manager | KMS encrypted, IRSA access only |
| Grafana password | Secret | Secrets Manager | KMS encrypted |
| Alertmanager credentials | Secret | Secrets Manager | KMS encrypted, never in Git |
| Container images | Internal | ECR Private | IAM controlled, scan-on-push |
| Terraform state | Internal | S3 | SSE-S3, versioned, public access blocked |
| Helm values / K8s manifests | Internal | Git (public repo) | No secrets — placeholders only |

---

## ECR Image Security

| Environment | Tag Mutability | Scan on Push | Lifecycle Policy |
|-------------|---------------|--------------|-----------------|
| Dev | MUTABLE | ✅ Enabled | Keep last 10, expire untagged after 7 days |
| Prod | IMMUTABLE | ✅ Enabled | Keep last 10, expire untagged after 7 days |

> **IMMUTABLE prod tags** prevent deployed images from being overwritten.
> A compromised CI pipeline cannot silently replace a running prod image.

---

## Vulnerability Scanning

| Scanner | When | Scope | Blocks |
|---------|------|-------|--------|
| Trivy (CI pipeline) | Every image build | CRITICAL + HIGH CVEs | Informational (does not block push) |
| ECR scan-on-push | Every image push to ECR | OS + package CVEs | Informational — review in ECR console |
| Checkov | Run manually | Terraform IaC | Manual review before apply |

**Trivy scan results:** Uploaded as GitHub Actions artifacts (30-day retention).
Accessible at: `https://github.com/paharipratyush/spring-petclinic-microservices/actions`

**Remediation SLAs:**
- Critical: 24 hours
- High: 72 hours
- Medium: 1 week
- Low: Next sprint

> **Note:** Trivy currently runs in informational mode — it does not block the CI
> pipeline on CRITICAL findings. For production hardening, change `exit-code` from
> `"0"` to `"1"` in `ecr-build-push.yml` to block pushes on CRITICAL CVEs.

---

## Data Residency

All resources deployed in `ap-south-1` (Mumbai, India).

To deploy in a different region, change `aws_region` in `terraform.tfvars`:
```hcl
aws_region = "us-east-1"
```

No region-specific hardcoding in modules — all regions supported.

---

## Network Security

| Control | Status | Details |
|---------|--------|---------|
| Public internet access | ✅ ALB only | Pods not directly internet-accessible |
| No NAT Gateway | ✅ Cost optimization | Nodes use public subnets with SG perimeter |
| RDS not publicly accessible | ✅ | `publicly_accessible = false` |
| S3 public access blocked | ✅ | All buckets |
| EKS public endpoint | ⚠️ Enabled | Required for `kubectl` access from developer workstations |
| Cross-SG rules | ✅ | Karpenter nodes ↔ managed nodes (Terraform managed) |

> **EKS public endpoint** is enabled for developer access. For higher security,
> restrict to specific IP CIDRs in `terraform.tfvars`:
> ```hcl
> eks_public_access_cidrs = ["your-ip/32"]
> ```

---

## Kubernetes Security

| Control | Status | Details |
|---------|--------|---------|
| `runAsNonRoot` | ✅ | Alertmanager pod (UID 65534) |
| `readOnlyRootFilesystem` | ⚠️ Partial | Not enforced on all app pods |
| Network Policies | ⚠️ Not configured | All pod-to-pod traffic allowed within namespace |
| Pod Security Standards | ⚠️ Warning mode | `restricted:latest` warnings on some pods |
| RBAC | ✅ | ArgoCD RBAC configured |
| Secrets not in env vars from ConfigMap | ✅ | All secrets via ESO → K8s Secrets |

---

## CI/CD Security

| Control | Status | Details |
|---------|--------|---------|
| No long-lived AWS keys | ✅ | GitHub Actions OIDC federation |
| OIDC scoped to main branch | ✅ | Trust policy: `ref:refs/heads/main` only |
| PLATFORM_REPO_TOKEN | ✅ | Fine-grained PAT — Contents:write on infra repo only |
| Image tags in Git | ✅ | All deployments traceable to commit SHA |
| Prod deploy requires manual approval | ✅ | ArgoCD manual sync — no auto-deploy to prod |
| Prod ECR tags immutable | ✅ | Cannot overwrite deployed image |

---

## Cost Controls

| Control | Status | Details |
|---------|--------|---------|
| Graviton free tier | ✅ | t4g nodes free until Dec 2026 |
| RDS free tier | ✅ | db.t4g.micro free 12 months |
| Destroy when idle | ✅ | `./scripts/full-cleanup.sh` |
| No NAT Gateway | ✅ | ~$32/month saving per env |
| No Route 53 | ✅ | Cloudflare free tier |
| Loki instead of CloudWatch | ✅ | ~$50+/month saving |
| Single-AZ RDS | ✅ | ~$15/month saving vs Multi-AZ |
