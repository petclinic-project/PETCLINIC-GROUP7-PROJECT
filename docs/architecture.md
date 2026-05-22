# Petclinic Platform — Architecture

## Overview

Spring Petclinic Microservices (8 Spring Boot services) deployed on AWS EKS,
managed via Terraform IaC, deployed via ArgoCD GitOps, monitored with
Prometheus/Grafana/Loki/Zipkin. Two environments — dev (auto-deploy) and
prod (manual approval) — run on separate EKS clusters with separate VPCs,
ECR repos, and RDS instances.

---

## Repository Structure

```
petclinic-infra/
├── terraform/
│   ├── environments/
│   │   ├── dev/          # Dev root module
│   │   └── prod/         # Prod root module
│   └── modules/
│       ├── vpc/          # VPC, subnets, security groups
│       ├── eks/          # EKS cluster, node groups, IRSA, add-ons
│       ├── ecr/          # ECR repos, lifecycle policies
│       ├── rds/          # RDS MySQL, credentials
│       ├── dns/          # ACM cert, Cloudflare DNS records
│       ├── secrets/      # Secrets Manager secrets, ESO IRSA role
│       ├── karpenter/    # Karpenter IAM, SQS, EventBridge
│       └── github-oidc/  # GitHub Actions OIDC federation, ECR push policy
├── helm/
│   └── petclinic-service/ # Generic Helm chart for all 8 services
├── helm-values/
│   ├── dev/              # Per-service values for dev (ECR dev URL, dev RDS)
│   │   └── {service}.yaml
│   ├── prod/             # Per-service values for prod (ECR prod URL, prod RDS)
│   │   └── {service}.yaml
│   ├── dev.yaml          # Dev-wide overrides (replicaCount=1)
│   └── prod.yaml         # Prod-wide overrides (replicaCount=2)
├── argocd/
│   ├── install/          # ArgoCD installation script
│   ├── applications/dev/ # 9 ArgoCD Application CRDs (auto-sync)
│   └── applications/prod/# 9 ArgoCD Application CRDs (manual sync)
├── k8s/
│   ├── base/
│   │   ├── namespaces.yaml
│   │   ├── external-secrets/  # ClusterSecretStore, ServiceAccount
│   │   └── karpenter/         # NodePool, EC2NodeClass
│   └── overlays/
│       ├── dev/          # ExternalSecrets, Ingress for dev
│       └── prod/         # ExternalSecrets, Ingress for prod
├── monitoring/
│   ├── prometheus-values.yaml
│   ├── grafana-values.yaml
│   ├── loki-values.yaml
│   ├── fluent-bit-values.yaml
│   ├── alertmanager.yaml      # PVC + Deployment + Service (Secret managed separately)
│   ├── zipkin.yaml
│   └── monitoring-ingress.yaml
├── scripts/               # Operational scripts (see Scripts Reference)
└── docs/                  # Documentation and ADRs
```

---

## AWS Infrastructure

### Network (VPC)

- **Design:** All-public subnets (see ADR-0001)
- **Dev VPC:** `10.0.0.0/16`, 2 subnets across 2 AZs
- **Prod VPC:** `10.1.0.0/16`, 2 subnets across 2 AZs
- **Security groups per environment:**
  - `eks-cluster-sg` — EKS control plane
  - `eks-node-sg` — Worker nodes + Karpenter nodes
  - `rds-sg` — MySQL (only accessible from node SG)
  - `alb-sg` — Load balancer (0.0.0.0/0 on 443)
- **Cross-SG rules:** Karpenter nodes ↔ managed nodes (required for pod networking)
- **No NAT Gateway** — cost optimization, security groups are the perimeter

### Compute (EKS)

- **Kubernetes:** v1.30, ARM64 architecture
- **Managed nodes:** 2x `t4g.medium` ARM64/Graviton (free trial until Dec 2026)
- **Node autoscaling:** Karpenter v1.1.1
  - NodePool: `t4g.small` on-demand (cost optimized)
  - EC2NodeClass: discovery via `karpenter.sh/discovery` tag
  - Scales up when pods are Pending, scales down on idle
- **Add-ons:** CoreDNS, kube-proxy, vpc-cni, EBS CSI Driver
- **OIDC:** Enabled for IRSA

### Container Registry (ECR)

- **Separate repos per environment:**
  - Dev: `petclinic-dev/{service}` — MUTABLE tags
  - Prod: `petclinic-prod/{service}` — IMMUTABLE tags
- **8 repos per environment** (one per service)
- **Lifecycle policy:** Keep last 10 images, expire untagged after 7 days
- **GitHub Actions push policy:** Wildcard `petclinic-*/*` covers all environments
- **Scan on push:** Enabled (ECR basic scanning)

### Database (RDS)

- **Engine:** MySQL 8.0, `db.t4g.micro` (free tier)
- **Shared `petclinic` database** for customers, visits, vets services (ADR-0003)
- **Single-AZ** both environments (ADR-0006)
- **Credentials:** Stored in AWS Secrets Manager, synced to K8s via ESO
- **DB init mode:**
  - Dev: `SPRING_SQL_INIT_MODE=always` — seeds test data on every startup
  - Prod: `SPRING_SQL_INIT_MODE=never` — schema exists, prevents re-seeding
  - Fresh prod RDS: run `./scripts/seed-prod-data.sh` once after first deploy
- **Connection pool (prod):** `HIKARI_MAXIMUM_POOL_SIZE=5` to avoid RDS `max_connections` limit
  (db.t4g.micro has ~60 max connections; 3 services × 2 replicas × 5 = 30)

### DNS and TLS

- **Domain:** Managed in Cloudflare (see `docs/setup/dns-provider-guide.md` for Route53)
- **TLS:** ACM wildcard certificate `*.praty.dev`, validated via Cloudflare DNS CNAME
- **Ingress:** AWS ALB Ingress Controller (IRSA), internet-facing
- **SSL termination:** At ALB — backend pods receive HTTP

| Subdomain | Dev | Prod |
|-----------|-----|------|
| App | `petclinic-dev.praty.dev` | `petclinic.praty.dev` |
| Grafana | `grafana-dev.praty.dev` | `grafana.praty.dev` |
| ArgoCD | `argocd-dev.praty.dev` | `argocd.praty.dev` |
| Admin | `admin-dev.praty.dev` | `admin.praty.dev` |
| Zipkin | `zipkin-dev.praty.dev` | `zipkin.praty.dev` |

> **Cloudflare CNAME note:** Both dev and prod ACM certs use the same validation
> CNAME name. `pre-apply-check.sh` handles importing the existing Cloudflare record
> automatically — no manual steps needed on re-deploy.

### Secrets Management

- **AWS Secrets Manager** stores: RDS credentials, OpenAI API key, Grafana password, Alertmanager Gmail credentials
- **External Secrets Operator (ESO):** Syncs Secrets Manager → Kubernetes Secrets every 1 hour
- **ClusterSecretStore:** Single store with IRSA for both petclinic namespaces and monitoring
- **Alertmanager credentials:** Injected at deploy time by `setup-cluster.sh` using Python
  (shell `tr -d ' '` strips spaces from Gmail app passwords — Python preserves them)

---

## Application Services

| Service | Port | MySQL | Spring Profile | Startup Order |
|---------|------|-------|----------------|--------------|
| config-server | 8888 | No | `docker` | 1st — all others depend on it |
| discovery-server | 8761 | No | `docker` | 2nd — all others register |
| api-gateway | 8080 | No | `docker` | 3rd+ |
| customers-service | 8081 | Yes | `docker,mysql` | 3rd+ |
| visits-service | 8082 | Yes | `docker,mysql` | After customers (FK dependency) |
| vets-service | 8083 | Yes | `docker,mysql,production` | 3rd+ |
| genai-service | 8084 | No | `docker,production` | 3rd+ |
| admin-server | 9090 | No | `docker` | 3rd+ |

**Startup order enforced** via init containers polling health endpoints:
- All services wait for `config-server:8888/actuator/health`
- All services wait for `zipkin.tracing:9411/health`
- `api-gateway` additionally waits for `discovery-server:8761/actuator/health`

**visits-service FK fix:** visits table has a foreign key on pets table created by
customers-service. `setup-cluster.sh` waits for customers-service to be ready before
allowing visits-service to start, preventing FK constraint errors.

---

## Helm Chart Design

Single generic chart at `helm/petclinic-service` serves all 8 services.

**Value file loading order (ArgoCD):**
helm-values/{env}/{service}.yaml   ← service-specific (ECR URL, ports, env vars, image tag)
helm-values/{env}.yaml              ← environment-wide (replicaCount, resource limits)

**Why separated into `dev/` and `prod/` subdirectories:**
- Prevents cross-contamination when `generate-config.sh` runs for different environments
- CI/CD pipeline (`update-image-tags.yml`) only writes to `helm-values/dev/`
- Prod tags only change via manual promotion through `promote-to-prod.sh`

---

## CI/CD Pipeline

```
Developer pushes to spring-petclinic-microservices main branch
             ↓
GitHub Actions: build-push.yml
├─ detect-changes: paths-filter detects ONLY changed service dirs
├─ build (per changed service):
│   ├─ Setup Java 17 (Temurin) + Maven cache
│   ├─ QEMU + Buildx for linux/arm64 cross-compilation
│   ├─ Configure AWS OIDC (no long-lived keys)
│   ├─ Maven build: ./mvnw -P buildDocker -pl {service} -am
│   ├─ Trivy scan (CRITICAL — informational, does not block)
│   └─ Push to ECR: petclinic-dev/{service}:{7-char-sha}
└─ notify: repository_dispatch → petclinic-infra
             ↓
GitHub Actions: update-image-tags.yml (infra repo)
├─ Checkout with PLATFORM_REPO_TOKEN
├─ yq update: helm-values/dev/{service}.yaml .image.tag = {sha}
└─ Commit and push
             ↓
ArgoCD (polls infra repo every 3 min)
├─ Dev: auto-syncs → rolling deploy (zero downtime)
└─ Prod: shows OutOfSync → requires manual Sync in UI
```

### Prod Promotion Flow
1. CI builds image → pushes to petclinic-dev/{service}:{sha}
2. Dev auto-deploys and validates
3. Operator promotes:
  a. docker pull petclinic-dev/{service}:{sha}
  b. docker tag  → petclinic-prod/{service}:{sha}
  c. docker push → petclinic-prod/{service}:{sha}
  d. yq -i ".image.tag = {sha}" helm-values/prod/{service}.yaml
  e. git commit && git push
4. ArgoCD prod shows OutOfSync
5. Operator clicks Sync in ArgoCD UI (manual approval gate)
6. ArgoCD rolling deploy — zero downtime

### GitHub Actions Authentication

- **OIDC federation** — no long-lived AWS keys stored in GitHub (ADR-0005)
- Trust policy: restricts to `main` branch of app repo only
- **ECR policy:** Wildcard `petclinic-*/*` covers both dev and prod repos
  (shared role — must cover all environments)
- **PLATFORM_REPO_TOKEN:** Fine-grained PAT with Contents:write on infra repo

---

## Observability Stack

All components in `monitoring` namespace (Zipkin in `tracing`).

| Component | Version | Purpose |
|-----------|---------|---------|
| Prometheus | 25.21.0 (chart) | Metrics scraping + alert rules |
| Grafana | 7.3.9 (chart) | Dashboards, log exploration |
| Loki | 6.6.2 (chart) | Log aggregation |
| FluentBit | 0.46.7 (chart) | Log collection DaemonSet → Loki |
| Alertmanager | v0.27.0 | Alert routing → Gmail |
| Zipkin | latest | Distributed tracing |
| Metrics Server | latest | `kubectl top` + HPA |

### Prometheus Scrape Targets

Only 5 of 8 services expose Prometheus metrics (have `micrometer-registry-prometheus`):
`api-gateway`, `customers-service`, `visits-service`, `vets-service`, `genai-service`

`config-server`, `discovery-server`, `admin-server` do NOT have this dependency.

### Alert Rules

| Alert | Condition | Severity | Action |
|-------|-----------|----------|--------|
| `ServiceDown` | `up{job=~"..."}==0` for 1m | critical | Email via Gmail SMTP |
| `HighErrorRate` | HTTP 5xx rate > threshold | warning | Email |
| `HighLatency` | P95 > threshold | warning | Email |

### Alertmanager Email Setup

- Gmail SMTP with App Password (not account password)
- Credentials stored in AWS Secrets Manager as `petclinic/{env}/alertmanager-email`
- Injected at deploy time by `setup-cluster.sh` using Python (preserves spaces in app password)
- `send_resolved: true` — sends both firing and resolved notifications

### Distributed Tracing (Zipkin)

- Spring Boot services configured with `management.zipkin.tracing.endpoint`
- Sampling probability: 1.0 (100% in dev/prod for demo purposes)
- View traces at `https://zipkin-dev.praty.dev`

---

## Environment Comparison

| Setting | Dev | Prod |
|---------|-----|------|
| VPC CIDR | `10.0.0.0/16` | `10.1.0.0/16` |
| K8s namespace | `petclinic-dev` | `petclinic-prod` |
| Replicas per service | 1 | 2 |
| ArgoCD sync | Auto (≤3 min) | Manual approval |
| ECR tag mutability | MUTABLE | IMMUTABLE |
| DB init mode | `always` | `never` |
| HikariCP pool | 10 (default) | 5 (RDS limit) |
| Karpenter nodes | t4g.small on-demand | t4g.small on-demand |
| Subdomain prefix | `*-dev.praty.dev` | `*.praty.dev` |

---

## Security Model

- **No secrets in Git** — all credentials via AWS Secrets Manager + ESO
- **GitHub Actions OIDC** — no long-lived AWS keys stored anywhere
- **ECR IMMUTABLE tags (prod)** — deployed images cannot be overwritten
- **S3 state bucket** — public access blocked, versioning enabled
- **RDS** — only reachable from EKS node security group
- **ALB** — HTTPS only (port 443), HTTP redirects to HTTPS
- **ArgoCD RBAC** — admin full access, developers can only sync dev apps
- **Pod security** — `runAsNonRoot: true`, `readOnlyRootFilesystem` where possible

---

## Cost Estimate (Monthly)

| Resource | Dev | Prod | Notes |
|----------|-----|------|-------|
| EKS Control Plane | ~$73 | ~$73 | Unavoidable |
| EC2 t4g.medium (managed nodes) | $0 | $0 | Graviton free trial until Dec 2026 |
| EC2 t4g.small (Karpenter nodes) | $0 | $0 | Graviton free trial |
| RDS db.t4g.micro | $0 | $0 | 12-month free tier |
| ECR | ~$1 | ~$1 | Minimal storage |
| Secrets Manager | ~$2 | ~$2 | 4 secrets per env |
| S3, data transfer | ~$1 | ~$1 | State + logs |
| **Total per env** | **~$77** | **~$77** | |
| **Total both envs running** | | **~$154/month** | |

> **Cost tip:** EKS costs $0.10/hr per cluster. Destroy after each session:
> ```bash
> ./scripts/full-cleanup.sh
> ```
> Target: under $15 for the entire project by destroying when not in use.

---

## Known Operational Notes

### Terraform State Backend
- S3 native locking (`use_lockfile = true`) — Terraform >= 1.10 required
- `terraform output` hangs indefinitely on some systems (TLS provider v4.3.0 bug)
- **Fix:** `setup-cluster.sh` reads outputs directly from S3 state via Python

### Buildx Builder (WSL)
- Docker buildx builder becomes stale after Docker Desktop restart
- `build-push-images.sh` auto-detects and recreates the builder

### Alertmanager PVC
- Alertmanager uses a PVC — only one pod can mount it at a time
- Never run two alertmanager deployments simultaneously
- `alertmanager.yaml` contains only PVC + Deployment + Service (Secret managed separately
  by `setup-cluster.sh` to prevent placeholder overwrite)

### Prod Initial Data Seed
- Fresh prod RDS has no test data
- Run once after first prod deploy: `./scripts/seed-prod-data.sh`
- Temporarily enables `SPRING_SQL_INIT_MODE=always`, waits 90s, restores to `never`

---

## Architecture Decisions

See `docs/adr/` for all Architecture Decision Records.

| ADR | Decision |
|-----|----------|
| 0001 | Public subnets (cost vs security tradeoff) |
| 0002 | EKS over ECS (Kubernetes ecosystem) |
| 0003 | Shared RDS (cost optimization) |
| 0005 | GitHub Actions OIDC (no long-lived keys) |
| 0006 | Single-AZ RDS (cost optimization) |
| 0007 | Helm over plain YAML (templating + env separation) |
| 0008 | ArgoCD GitOps (auditability + drift detection) |
| 0009 | ECR private (security) |
| 0010 | AWS Secrets Manager (no secrets in Git) |
| 0011 | Loki over CloudWatch (cost + in-cluster) |
| 0012 | Cloudflare over Route53 (existing domain, free) |
| 0013 | Separate helm-values per env (no cross-contamination) |
| 0014 | Karpenter + Graviton (autoscaling + free tier) |
