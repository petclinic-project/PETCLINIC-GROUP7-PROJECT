# Petclinic Platform — AWS Infrastructure

Production AWS infrastructure for [Spring Petclinic Microservices](https://github.com/spring-petclinic/spring-petclinic-microservices) — 8 Spring Boot services deployed on Amazon EKS with full GitOps, observability, and security.

> **Reproducible by design.** Anyone with an AWS account, a domain name, and a GitHub account can deploy this from scratch using the scripts in this repo.

---

## What This Repo Does

Takes Spring Petclinic Microservices from Docker Compose to production on AWS:

 ```
Docker Compose (local)
      ↓
AWS EKS (production)

  - Terraform manages all AWS infrastructure (dev + prod)
  - Helm packages all 8 services with a single generic chart
  - ArgoCD handles all deployments (GitOps)
  - GitHub Actions builds and pushes images (CI only)
  - Prometheus + Grafana + Loki + Zipkin for observability
  - Karpenter for node autoscaling
  - Two environments: dev (auto-deploy) + prod (manual approval)
```

---

## Architecture

```
Internet
   │
   ▼
Cloudflare DNS (CNAME → ALB)
   │
   ▼
AWS ACM (TLS termination at ALB)
   │
   ▼
AWS ALB (created by ALB Ingress Controller)
   │
   ├─────────────────────────────────────────┐
   │                                         │
   ▼                                         ▼
DEV                                        PROD
petclinic-dev.your-domain.com    petclinic.your-domain.com
grafana-dev.your-domain.com      grafana.your-domain.com
argocd-dev.your-domain.com       argocd.your-domain.com
admin-dev.your-domain.com        admin.your-domain.com
zipkin-dev.your-domain.com       zipkin.your-domain.com
   │                                         │
   ▼                                         ▼
Amazon EKS (Kubernetes 1.30)     Amazon EKS (Kubernetes 1.30)
2x t4g.medium ARM64/Graviton     2x t4g.medium ARM64/Graviton
+ Karpenter t4g.small            + Karpenter t4g.small
   │                                         │
┌──┴──────────────────────────┐  ┌───────────┴─────────────────┐
│ petclinic-dev namespace     │  │ petclinic-prod namespace     │
│  8 services (1 replica ea)  │  │  8 services (2 replicas ea)  │
│  Auto-sync via ArgoCD       │  │  Manual approval via ArgoCD  │
└────────────┬────────────────┘  └────────────┬────────────────┘
             └──────────────┬─────────────────┘
                            │
                            ▼
                  Amazon RDS MySQL 8.0
                  AWS Secrets Manager
                  Amazon ECR (private)
```

### Tech Stack

| Layer | Tool | Details |
|-------|------|---------|
| Cloud | AWS | Any region |
| IaC | Terraform >= 1.10 | S3 backend, modular |
| Cluster | Amazon EKS 1.30 | ARM64 Graviton nodes |
| Autoscaling | Karpenter v1.1.1 | NodePool + EC2NodeClass |
| Registry | Amazon ECR | Private, separate dev/prod repos |
| Database | Amazon RDS MySQL 8.0 | Shared `petclinic` DB |
| DNS | Cloudflare (or Route 53) | Wildcard ACM cert |
| Secrets | AWS Secrets Manager + ESO | No secrets in Git |
| Ingress | AWS ALB Ingress Controller | IRSA, internet-facing |
| Packaging | Helm | Generic chart, per-service values |
| GitOps | ArgoCD | Auto-sync dev, manual prod |
| CI | GitHub Actions | OIDC, ARM64 builds, Trivy |
| Metrics | Prometheus + Grafana | 5 services instrumented |
| Logging | Loki + FluentBit | In-cluster, no CloudWatch |
| Tracing | Zipkin | OpenTelemetry |

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| AWS CLI | v2+ | [docs](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| Terraform | >= 1.10 | [docs](https://developer.hashicorp.com/terraform/install) |
| kubectl | latest | [docs](https://kubernetes.io/docs/tasks/tools/) |
| Helm | v3+ | [docs](https://helm.sh/docs/intro/install/) |
| Docker Desktop | latest | [docs](https://www.docker.com/products/docker-desktop/) |
| yq | v4+ | [docs](https://github.com/mikefarah/yq#install) |
| gh CLI | latest | [docs](https://cli.github.com) |
| git | any | pre-installed |

You also need:
- **AWS account** with IAM user that has sufficient permissions
- **Domain name** managed in Cloudflare (or Route 53 — see `docs/setup/dns-provider-guide.md`)
- **GitHub account** with a fork of [spring-petclinic-microservices](https://github.com/spring-petclinic/spring-petclinic-microservices)

---

## Quick Start

### Step 1 — Clone repos

```bash
mkdir ~/petclinic && cd ~/petclinic
git clone https://github.com/your-username/petclinic-infra.git
git clone https://github.com/your-username/spring-petclinic-microservices.git
cd petclinic-infra
chmod +x scripts/*.sh
```

### Step 2 — Configure AWS and Terraform

```bash
# Configure AWS credentials
aws configure

# Bootstrap Terraform state backend (run once per AWS account)
./scripts/bootstrap-state.sh

# Copy and fill in your values
cp terraform/environments/dev/terraform.tfvars.example \
   terraform/environments/dev/terraform.tfvars
nano terraform/environments/dev/terraform.tfvars
```

**Required values in `terraform.tfvars`:**

| Variable | Description | Example |
|----------|-------------|---------|
| `aws_region` | Your AWS region | `ap-south-1` |
| `domain_name` | Your domain | `example.com` |
| `iam_admin_username` | Your IAM username | `my-iam-user` |
| `github_org` | Your GitHub username | `myusername` |
| `cloudflare_zone_id` | Cloudflare Zone ID | from Cloudflare dashboard |
| `cloudflare_api_token` | Cloudflare API token | DNS edit permissions |
| `alertmanager_email` | Gmail address for alerts | `your@gmail.com` |
| `alertmanager_app_password` | Gmail app password | `xxxx xxxx xxxx xxxx` |

### Step 3 — Set Up CI/CD (One-Time)

```bash
# Authenticate GitHub CLI
gh auth login

# Configure all GitHub secrets and variables automatically
./scripts/setup-github-secrets.sh
# Paste your PLATFORM_REPO_TOKEN (fine-grained PAT) when prompted
# See docs/onboarding.md Step 10 for PAT creation instructions
```

### Step 4 — Deploy Dev Infrastructure

```bash
./scripts/tf.sh dev init
./scripts/tf.sh dev plan
./scripts/tf.sh dev apply   # ~15 min
```

### Step 5 — Configure and Deploy Dev Cluster

```bash
rm -f /tmp/tfstate-dev.json
./scripts/generate-config.sh dev
git add helm-values/dev/ k8s/ monitoring/ argocd/
git commit -m "config: update dynamic values for dev" && git push

./scripts/setup-cluster.sh dev
./scripts/build-push-images.sh --tag v1.0.0
./scripts/update-dns-and-ingress.sh dev
./scripts/smoke-test.sh petclinic-dev
```

### Step 6 — Deploy Prod Infrastructure (Optional)

```bash
cp terraform/environments/dev/terraform.tfvars \
   terraform/environments/prod/terraform.tfvars

./scripts/tf.sh prod init
./scripts/tf.sh prod apply

rm -f /tmp/tfstate-prod.json
./scripts/generate-config.sh prod
git add helm-values/prod/ k8s/ monitoring/ argocd/
git commit -m "config: update dynamic values for prod" && git push

aws eks update-kubeconfig --name petclinic-prod --region ap-south-1
./scripts/setup-cluster.sh prod
./scripts/build-push-images.sh --tag v1.0.0 --env prod
./scripts/update-dns-and-ingress.sh prod

# Prod has no auto-sync — trigger initial deployment manually
for APP in config-server-prod discovery-server-prod api-gateway-prod \
           customers-service-prod visits-service-prod vets-service-prod \
           genai-service-prod admin-server-prod; do
  kubectl patch application "${APP}" -n argocd \
    --type merge \
    -p '{"operation":{"sync":{"syncStrategy":{"apply":{"force":false}}}}}' \
    2>/dev/null && echo "Syncing: ${APP}"
done
sleep 180

# Seed prod RDS with test data (ONCE on fresh database)
./scripts/seed-prod-data.sh

aws eks update-kubeconfig --name petclinic-dev --region ap-south-1
./scripts/smoke-test.sh petclinic-prod
```

Your apps are live:
- **Dev App:** `https://petclinic-dev.your-domain.com`
- **Dev Grafana:** `https://grafana-dev.your-domain.com`
- **Dev ArgoCD:** `https://argocd-dev.your-domain.com`
- **Prod App:** `https://petclinic.your-domain.com`
- **Prod ArgoCD:** `https://argocd.your-domain.com`

---

## CI/CD Pipeline

```
Developer pushes to spring-petclinic-microservices main
              ↓
GitHub Actions: build-push.yml
  ├─ Detects ONLY changed services (paths-filter)
  ├─ Builds linux/arm64 Docker images (QEMU + Buildx)
  ├─ Trivy security scan
  ├─ Pushes to ECR: petclinic-dev/{service}:{7-char-sha}
  └─ Dispatches repository_dispatch to infra repo
              ↓
GitHub Actions: update-image-tags.yml (infra repo)
  ├─ Updates helm-values/dev/{service}.yaml image.tag = {sha}
  └─ Commits and pushes
              ↓
ArgoCD (polls infra repo every 3 min)
  ├─ Dev:  auto-syncs → rolling deploy (zero downtime)
  └─ Prod: shows OutOfSync → requires manual Sync in ArgoCD UI
```

### Prod Promotion Flow

```
1. CI auto-updates helm-values/dev/ with new SHA
2. Dev auto-deploys — validate it works
3. Copy image dev ECR → prod ECR (no rebuild):
      docker pull petclinic-dev/{service}:{sha}
      docker tag  → petclinic-prod/{service}:{sha}
      docker push → petclinic-prod/{service}:{sha}
4. Update helm-values/prod/{service}.yaml → commit → push
5. ArgoCD prod shows OutOfSync
6. Click Sync in ArgoCD UI → rolling deploy, zero downtime
```
### CI/CD Setup

```bash
# Automated via gh CLI:
./scripts/setup-github-secrets.sh

# Or manually add to app repo on GitHub:
# Secrets:   AWS_ROLE_ARN, PLATFORM_REPO_TOKEN
# Variables: AWS_REGION, AWS_ACCOUNT_ID, PLATFORM_REPO
```

See [onboarding guide](docs/onboarding.md#step-10--set-up-cicd-pipeline-15-min) for full instructions.

---

## Environments

| Setting | Dev | Prod |
|---------|-----|------|
| VPC CIDR | `10.0.0.0/16` | `10.1.0.0/16` |
| K8s namespace | `petclinic-dev` | `petclinic-prod` |
| ECR tag mutability | MUTABLE | IMMUTABLE |
| ArgoCD sync | Auto (≤3 min) | Manual approval |
| Replicas | 1 per service | 2 per service |
| DB init mode | `always` | `never` |
| HikariCP pool | 10 (default) | 5 (RDS limit) |
| Subdomain prefix | `*-dev.your-domain.com` | `*.your-domain.com` |

---

## Repository Structure

```
petclinic-infra/
│
├── terraform/
│   ├── environments/
│   │   ├── dev/               # Dev root module
│   │   └── prod/              # Prod root module
│   └── modules/
│       ├── vpc/               # VPC, subnets, security groups
│       ├── eks/               # EKS cluster, node groups, IRSA
│       ├── ecr/               # ECR repos, lifecycle policies
│       ├── rds/               # RDS MySQL, credentials
│       ├── dns/               # ACM cert, Cloudflare DNS records
│       ├── secrets/           # Secrets Manager, ESO IRSA role
│       ├── karpenter/         # Karpenter IAM, SQS, EventBridge
│       └── github-oidc/       # GitHub Actions OIDC federation
│
├── helm/
│   └── petclinic-service/     # Generic chart for all 8 services
│
├── helm-values/
│   ├── dev/                   # Per-service values for dev
│   │   └── {service}.yaml     # ECR dev URL, dev RDS, image tag
│   ├── prod/                  # Per-service values for prod
│   │   └── {service}.yaml     # ECR prod URL, prod RDS, image tag
│   ├── dev.yaml               # Dev-wide overrides (replicaCount=1)
│   └── prod.yaml              # Prod-wide overrides (replicaCount=2)
│
├── argocd/
│   ├── install/               # ArgoCD installation script + README
│   ├── applications/dev/      # 9 ArgoCD Apps (auto-sync)
│   ├── applications/prod/     # 9 ArgoCD Apps (manual sync)
│   └── argocd-rbac-cm.yaml
│
├── k8s/
│   ├── base/
│   │   ├── namespaces.yaml
│   │   ├── external-secrets/  # ClusterSecretStore, ServiceAccount
│   │   └── karpenter/         # NodePool, EC2NodeClass, Spot override
│   └── overlays/
│       ├── dev/               # ExternalSecrets, Ingress for dev
│       └── prod/              # ExternalSecrets, Ingress for prod
│
├── monitoring/
│   ├── prometheus-values.yaml # Scrape config + alert rules
│   ├── grafana-values.yaml    # Datasources, dashboards, root_url
│   ├── loki-values.yaml
│   ├── fluent-bit-values.yaml
│   ├── alertmanager.yaml      # PVC + Deployment + Service
│   ├── zipkin.yaml
│   └── monitoring-ingress.yaml
│
├── .github/workflows/
│   └── update-image-tags.yml  # Triggered by app repo dispatch
│
├── scripts/
│   ├── bootstrap-state.sh     # Create S3 state bucket (run once)
│   ├── pre-apply-check.sh     # Import shared resources before apply
│   ├── tf.sh                  # Terraform wrapper (plan + apply)
│   ├── generate-config.sh     # Inject dynamic values after apply
│   ├── setup-cluster.sh       # Full cluster setup
│   ├── build-push-images.sh   # Build ARM64 images + push to ECR
│   ├── promote-to-prod.sh     # Copy dev→prod ECR + sync ArgoCD
│   ├── seed-prod-data.sh      # One-time prod RDS data seed
│   ├── setup-github-secrets.sh# Configure CI/CD secrets via gh CLI
│   ├── update-dns-and-ingress.sh # Wire Cloudflare DNS to ALBs
│   ├── smoke-test.sh          # Verify all 8 services healthy
│   ├── pre-destroy.sh         # Cleanup before terraform destroy
│   └── full-cleanup.sh        # Destroy everything (dev + prod)
│
├── config/                    # Generated backend HCL (gitignored)
│
└── docs/
    ├── architecture.md
    ├── runbook.md
    ├── incident-playbook.md
    ├── onboarding.md
    ├── compliance-checklist.md
    ├── setup/
    │      └── dns-provider-guide.md
    └── adr/                   # 14 Architecture Decision Records

```
---

## Key Scripts Reference

| Script | Purpose | Usage |
|--------|---------|-------|
| `bootstrap-state.sh` | Create S3 state bucket | Run once per account |
| `pre-apply-check.sh` | Import shared resources | Auto-called by `tf.sh` |
| `tf.sh` | Terraform wrapper | `./scripts/tf.sh dev apply` |
| `generate-config.sh` | Inject dynamic values | After every `terraform apply` |
| `setup-cluster.sh` | Full cluster setup | After first `terraform apply` |
| `build-push-images.sh` | Build ARM64 + push ECR | `--tag v1.0.0 --env dev` |
| `promote-to-prod.sh` | Copy dev→prod + sync | `--tag SHA` |
| `seed-prod-data.sh` | Seed prod RDS once | After fresh prod deploy |
| `setup-github-secrets.sh` | Configure CI/CD secrets | Run once |
| `update-dns-and-ingress.sh` | Wire DNS to ALBs | After ingresses applied |
| `smoke-test.sh` | Verify all services healthy | `petclinic-dev` or `petclinic-prod` |
| `pre-destroy.sh` | Clean up before destroy | Before `tf.sh dev destroy` |
| `full-cleanup.sh` | Destroy everything | Type `destroy` when prompted |

---

## Cost

| Resource | Dev | Prod | Notes |
|----------|-----|------|-------|
| EKS Control Plane | ~$73 | ~$73 | Unavoidable |
| EC2 t4g.medium (managed) | $0 | $0 | Graviton free trial until Dec 2026 |
| EC2 t4g.small (Karpenter) | $0 | $0 | Graviton free trial |
| RDS db.t4g.micro | $0 | $0 | 12-month free tier |
| ECR storage | ~$1 | ~$1 | Minimal |
| Secrets Manager | ~$2 | ~$2 | 4 secrets per env |
| S3, DNS, data transfer | ~$1 | ~$1 | |
| **Total per env** | **~$77** | **~$77** | |
| **Total both running** | | **~$154/month** | |

> **Cost tip:** EKS costs $0.10/hr per cluster. Destroy after each session:
> ```bash
> ./scripts/full-cleanup.sh
> ```
> Target: under $15 for the entire project by destroying when not in use.

---

## Security

- No secrets in Git — all via AWS Secrets Manager + External Secrets Operator
- GitHub Actions OIDC federation — no long-lived AWS keys stored anywhere
- ECR prod repos use IMMUTABLE tags — deployed images cannot be overwritten
- All S3 buckets have public access blocked
- RDS only reachable from EKS nodes via security group rules
- ALB HTTPS only — HTTP redirects to HTTPS
- ArgoCD RBAC: admin full access, developer can only sync dev apps
- Prod deploy requires manual ArgoCD UI approval — no accidental prod deploys

---

## Application Services

| Service | Port | Role |
|---------|------|------|
| config-server | 8888 | Git-backed config for all services |
| discovery-server | 8761 | Eureka service registry |
| api-gateway | 8080 | Routes all traffic, serves frontend |
| customers-service | 8081 | Owners + pets data (MySQL) |
| visits-service | 8082 | Visit records (MySQL) |
| vets-service | 8083 | Vet data + Caffeine cache (MySQL) |
| genai-service | 8084 | AI chatbot via Spring AI + OpenAI |
| admin-server | 9090 | Spring Boot Admin dashboard |

Source: [spring-petclinic-microservices](https://github.com/spring-petclinic/spring-petclinic-microservices)

---

## Documentation

| Doc | Purpose |
|-----|---------|
| [Architecture](docs/architecture.md) | Full AWS + K8s architecture, CI/CD flow, cost |
| [Runbook](docs/runbook.md) | Day-2 operations — restart, scale, rollback, ArgoCD, RDS |
| [Incident Playbook](docs/incident-playbook.md) | 12 common failure scenarios + fixes |
| [Onboarding Guide](docs/onboarding.md) | New engineer setup in under 90 min |
| [Compliance Checklist](docs/compliance-checklist.md) | Security, encryption, IAM, secrets audit |
| [DNS Provider Guide](docs/setup/dns-provider-guide.md) | Cloudflare + Route 53 setup + comparison |
| [ArgoCD README](argocd/install/README.md) | ArgoCD install, dev vs prod sync, RBAC |
| [ADRs](docs/adr/) | 14 architecture decision records |

---

## DNS Provider Options

This repo defaults to **Cloudflare** for DNS. See `docs/setup/dns-provider-guide.md`
to switch to Route 53.

| Provider | Setup Effort | Cost | Notes |
|----------|-------------|------|-------|
| Cloudflare | Add zone_id + API token to tfvars | Free | Default — requires import logic for CNAME conflict |
| Route 53 | Domain must be in Route 53 | ~$0.50/zone/month | Simpler Terraform — no CNAME conflict |

