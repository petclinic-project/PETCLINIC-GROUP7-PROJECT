# ADR-0012: Cloudflare over Route 53 for DNS Management

**Status:** Accepted
**Date:** 2025

---

## Context

The platform needs DNS management for custom subdomains pointing to AWS ALBs,
and ACM certificate validation via DNS records. Two options were evaluated:

1. **AWS Route 53** — native AWS DNS, used in mentor's original spec
2. **Cloudflare** — third-party DNS, already managing the `praty.dev` domain

The mentor's original technical specification used Route 53. However, the
domain `praty.dev` was already registered and managed in Cloudflare, making
migration to Route 53 impractical.

---

## Decision

Use Cloudflare for DNS management via the `cloudflare/cloudflare` Terraform
provider. ACM certificates are still issued by AWS — only the DNS validation
records and ALB CNAME records are in Cloudflare.

---

## How It Works

ACM requests wildcard cert for *.praty.dev
↓
ACM provides validation CNAME record
↓
Terraform creates CNAME in Cloudflare
↓
ACM validates → cert issued
↓
Terraform creates CNAME records in Cloudflare:
petclinic-dev.praty.dev → ALB DNS name
grafana-dev.praty.dev   → ALB DNS name
etc.

---

## Known Issues and Fixes Applied

### Issue 1 — ACM Validation CNAME Conflict

**Problem:** Both dev and prod ACM wildcard certs generate the same validation
CNAME name (`_acm-challenge.praty.dev`). When the second environment deploys,
Terraform tries to create a duplicate CNAME and fails.

**Root cause:** ACM validation for `*.domain.com` always produces the same DNS
challenge name regardless of which environment requests it. Route 53 handles
this with `allow_overwrite = true` — Cloudflare provider does not support this.

**Fix:** `scripts/pre-apply-check.sh` automatically imports the existing
Cloudflare CNAME record into Terraform state before apply. This way Terraform
manages the existing record rather than trying to create a duplicate.

### Issue 2 — `for_each` on Unknown ACM Values

**Problem:** ACM cert domain validation options are unknown at plan time.
Using dynamic keys in `for_each` causes:
Error: Invalid for_each argument — depends on resource attributes that cannot be determined until apply

**Fix:** `terraform/modules/dns/main.tf` uses a static key known at plan time:
```hcl
resource "cloudflare_record" "acm_validation" {
  for_each = {
    "*.${var.domain_name}" = tolist(
      aws_acm_certificate.wildcard.domain_validation_options
    )[0]
  }
}
```

### Issue 3 — Shared IAM OIDC Provider

**Problem:** The GitHub Actions OIDC provider is created by dev Terraform and
shared with prod. `pre-apply-check.sh` imports it into prod state automatically.

---

## Consequences

- **Free:** Cloudflare DNS management is free vs Route 53 ~$0.50/zone/month
- **DDoS protection:** Cloudflare's global network provides basic DDoS protection
- **Extra Terraform provider:** `cloudflare/cloudflare` added to all environment
  `versions.tf` and `providers.tf` files
- **Pre-apply automation required:** `pre-apply-check.sh` must run before every
  `terraform apply` to handle CNAME import — adds complexity not needed with Route 53
- **Cloudflare API token required:** Additional credential in `terraform.tfvars`
  (`cloudflare_zone_id`, `cloudflare_api_token`)
- **Migration path documented:** `docs/setup/dns-provider-guide.md` explains
  how to switch to Route 53 if needed

## Alternatives Considered

**Route 53 (mentor's approach):** Would eliminate all Cloudflare-specific
complexity. `allow_overwrite = true` handles the CNAME conflict natively.
Rejected because the domain was already in Cloudflare — migration would
take 5-7 days and add cost.

**Manual DNS management:** Update Cloudflare DNS manually after each deploy.
Rejected — not reproducible, defeats GitOps principles.
