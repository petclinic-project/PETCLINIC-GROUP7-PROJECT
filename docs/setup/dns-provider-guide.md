# DNS Provider Guide

This project supports two DNS management approaches depending on where your
domain is registered. Choose the one that applies to you.

---

## Option A: Cloudflare (default in this repo)

**Use this if:** Your domain is managed in Cloudflare — either registered
there or using Cloudflare as your DNS nameserver.

### What's already configured

- `terraform/modules/dns/main.tf` uses `cloudflare_record` resources
- `terraform/modules/dns/versions.tf` declares `cloudflare/cloudflare` provider
- `terraform/environments/dev/versions.tf` and `prod/versions.tf` declare Cloudflare provider
- `terraform/environments/dev/providers.tf` and `prod/providers.tf` configure the Cloudflare provider
- `scripts/pre-apply-check.sh` handles the Cloudflare CNAME conflict automatically

### What you need

1. **Cloudflare Zone ID** — Dashboard → your domain → Overview → right sidebar
2. **Cloudflare API Token** — Profile → API Tokens → Create Token →
   "Edit zone DNS" template → Specific zone → your domain

### What to add to terraform.tfvars

```hcl
cloudflare_zone_id   = "your-zone-id-here"
cloudflare_api_token = "your-api-token-here"
```

### Subdomains created automatically

| Subdomain | Purpose |
|-----------|---------|
| `petclinic-dev.your-domain.com` | Application (dev) |
| `grafana-dev.your-domain.com` | Grafana (dev) |
| `argocd-dev.your-domain.com` | ArgoCD (dev) |
| `admin-dev.your-domain.com` | Spring Boot Admin (dev) |
| `zipkin-dev.your-domain.com` | Zipkin tracing (dev) |
| `petclinic.your-domain.com` | Application (prod) |
| `grafana.your-domain.com` | Grafana (prod) |
| `argocd.your-domain.com` | ArgoCD (prod) |
| `admin.your-domain.com` | Spring Boot Admin (prod) |
| `zipkin.your-domain.com` | Zipkin tracing (prod) |

---

## Known Cloudflare Issues and Fixes

### Issue 1 — ACM Validation CNAME Conflict (Dev + Prod)

**Problem:** Both dev and prod ACM wildcard certificates generate the same
validation CNAME record name (`_acm-challenge.your-domain.com`). When the
second environment is deployed, Terraform tries to create a CNAME that already
exists in Cloudflare and fails with a conflict error.

**Root cause:** ACM cert validation for `*.your-domain.com` always produces
the same DNS challenge regardless of which environment requests it. This is
standard ACM behavior — one validation record covers all certs for the same domain.

**Fix applied:** `scripts/pre-apply-check.sh` automatically imports the
existing Cloudflare CNAME record into Terraform state before apply. No manual
steps needed.

```bash
# pre-apply-check.sh handles this automatically:
./scripts/pre-apply-check.sh dev   # imports existing CNAME if present
./scripts/tf.sh dev apply
```

**Why Route 53 doesn't have this issue:** The `aws_route53_record` resource
supports `allow_overwrite = true`, which silently handles duplicate records.
Cloudflare's Terraform provider does not have this option — it fails on
duplicate records.

### Issue 2 — Static Key for `for_each` in dns/main.tf

**Problem:** ACM cert domain validation options are unknown at plan time
(the cert hasn't been created yet). Using dynamic keys in `for_each` causes:
Error: Invalid for_each argument — depends on resource attributes that cannot be determined until apply

**Fix applied:** `terraform/modules/dns/main.tf` uses a static key
`"*.${var.domain_name}"` instead of the dynamic certificate output:

```hcl
# Static key — known at plan time
resource "cloudflare_record" "acm_validation" {
  for_each = {
    "*.${var.domain_name}" = tolist(aws_acm_certificate.wildcard.domain_validation_options)[0]
  }
  ...
}
```

This is already in the repo — no manual changes needed.

### Issue 3 — Shared IAM Role Conflict (Dev + Prod)

**Problem:** The GitHub Actions OIDC role (`petclinic-github-actions-role`)
is shared between dev and prod. When prod deploys, Terraform finds the role
already exists from dev and fails.

**Fix applied:** `scripts/pre-apply-check.sh` imports the shared role into
prod Terraform state automatically before apply.

---

## Option B: Route 53 (mentor's original approach)

**Use this if:** Your domain is managed in AWS Route 53 — either registered
there or using Route 53 as your DNS nameserver.

**Advantages over Cloudflare for this project:**
- No CNAME conflict issue (`allow_overwrite = true` handles duplicates)
- No `for_each` unknown value issue (Route 53 + ACM integrate natively)
- No need for `pre-apply-check.sh` import logic for DNS records
- Single AWS provider — no Cloudflare provider needed

**Disadvantage:**
- Route 53 costs ~$0.50/zone/month
- Requires domain nameservers pointing to Route 53

### Step 1: Point your domain's nameservers to Route 53

Get your Route 53 nameservers:
```bash
aws route53 get-hosted-zone \
  --id <your-zone-id> \
  --query 'DelegationSet.NameServers'
```

Then update nameservers at your registrar:
- **GoDaddy:** My Domains → DNS → Nameservers → Custom
- **Namecheap:** Domain List → Manage → Nameservers → Custom DNS
- **Google Domains:** DNS → Use custom name servers

> **Cloudflare registered domains:** Cloudflare free plan does NOT allow
> changing nameservers away from Cloudflare. Use Option A instead.

### Step 2: Replace dns module files

Replace `terraform/modules/dns/versions.tf`:
```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

Replace `terraform/modules/dns/main.tf`:
```hcl
data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

resource "aws_acm_certificate" "wildcard" {
  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-wildcard-cert"
  })
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.wildcard.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true   # handles dev+prod sharing same CNAME
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.main.zone_id
}

resource "aws_acm_certificate_validation" "wildcard" {
  certificate_arn         = aws_acm_certificate.wildcard.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

resource "aws_route53_record" "app" {
  count   = var.alb_dns_name != "" ? 1 : 0
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.environment == "prod" ? "petclinic" : "petclinic-${var.environment}"
  type    = "CNAME"
  ttl     = 60
  records = [var.alb_dns_name]
}

resource "aws_route53_record" "grafana" {
  count   = var.alb_dns_name != "" ? 1 : 0
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.environment == "prod" ? "grafana" : "grafana-${var.environment}"
  type    = "CNAME"
  ttl     = 60
  records = [var.alb_dns_name]
}

resource "aws_route53_record" "argocd" {
  count   = var.alb_dns_name != "" ? 1 : 0
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.environment == "prod" ? "argocd" : "argocd-${var.environment}"
  type    = "CNAME"
  ttl     = 60
  records = [var.alb_dns_name]
}

resource "aws_route53_record" "admin" {
  count   = var.alb_dns_name != "" ? 1 : 0
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.environment == "prod" ? "admin" : "admin-${var.environment}"
  type    = "CNAME"
  ttl     = 60
  records = [var.alb_dns_name]
}

resource "aws_route53_record" "zipkin" {
  count   = var.alb_dns_name != "" ? 1 : 0
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.environment == "prod" ? "zipkin" : "zipkin-${var.environment}"
  type    = "CNAME"
  ttl     = 60
  records = [var.alb_dns_name]
}
```

### Step 3: Remove Cloudflare from versions.tf

In `terraform/environments/dev/versions.tf` and `prod/versions.tf`,
remove the cloudflare provider block:
```hcl
# Remove this block:
cloudflare = {
  source  = "cloudflare/cloudflare"
  version = "~> 4.0"
}
```

### Step 4: Remove Cloudflare from providers.tf

In `terraform/environments/dev/providers.tf` and `prod/providers.tf`,
remove:
```hcl
# Remove this block:
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
```

### Step 5: Remove Cloudflare variables

Remove `cloudflare_zone_id` and `cloudflare_api_token` from:
- `terraform/environments/dev/variables.tf`
- `terraform/environments/dev/terraform.tfvars`
- `terraform/environments/prod/variables.tf`
- `terraform/environments/prod/terraform.tfvars`

### Step 6: Update dns module call in main.tf

Remove `cloudflare_zone_id` from the dns module call in both
`terraform/environments/dev/main.tf` and `prod/main.tf`:
```hcl
module "dns" {
  source      = "../../modules/dns"
  project     = var.project
  environment = var.environment
  domain_name = var.domain_name
  tags        = local.common_tags
}
```

### Step 7: Remove Cloudflare import from pre-apply-check.sh

In `scripts/pre-apply-check.sh`, the Cloudflare CNAME import steps
([4/5] section) are no longer needed. Remove or comment them out.

### Step 8: Reinitialize and apply

```bash
cd terraform/environments/dev
rm .terraform.lock.hcl
terraform init -backend-config=../../../config/backend-dev.hcl
cd ~/petclinic-infra
./scripts/tf.sh dev plan
./scripts/tf.sh dev apply
```

---

## DNS Architecture Comparison

| Aspect | Cloudflare (Option A) | Route 53 (Option B) |
|--------|----------------------|---------------------|
| Cost | Free | ~$0.50/zone/month |
| CNAME conflict (dev+prod) | ⚠️ Requires import logic | ✅ `allow_overwrite = true` |
| `for_each` unknown values | ⚠️ Requires static key workaround | ✅ Native integration |
| Terraform providers needed | `aws` + `cloudflare` | `aws` only |
| DDoS protection | ✅ Cloudflare network | Basic |
| Complexity | Higher (import logic) | Lower |
| Pre-apply-check needed | ✅ For CNAME import | ❌ Not needed for DNS |

---

## How DNS + HTTPS Works in This Project


Browser → petclinic-dev.your-domain.com
    ↓
[1] DNS: Cloudflare/Route53 resolves CNAME
petclinic-dev.your-domain.com → k8s-petclinic-xyz.ap-south-1.elb.amazonaws.com
    ↓
[2] HTTPS: Browser connects to AWS ALB on port 443
ALB presents *.your-domain.com ACM certificate
Browser verifies cert → connection encrypted 🔒
    ↓
[3] Routing: ALB checks Host header
petclinic-dev.your-domain.com → api-gateway:8080
grafana-dev.your-domain.com   → grafana:3000
argocd-dev.your-domain.com    → argocd-server:80
    ↓
[4] App: Kubernetes pod serves response

**ACM wildcard cert** `*.your-domain.com` covers all subdomains with one
certificate — no need for separate certs per service.

**SSL termination at ALB** — pods receive unencrypted HTTP internally.
The VPC security groups ensure only the ALB can reach the pods.



