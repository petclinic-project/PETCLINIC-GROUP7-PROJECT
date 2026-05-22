# ADR-0001: All-Public Subnet Design (No NAT Gateway)

**Status:** Accepted
**Date:** 2025

---

## Context

Standard AWS production architectures use private subnets with NAT Gateways
for outbound internet access from nodes. However, NAT Gateways cost a minimum
of ~$32/month per AZ plus data transfer fees — significant for a learning project.

---

## Decision

Use all-public subnets for all resources (EKS nodes, RDS, ALB). Security groups
enforce access control as the primary network boundary.

---

## Consequences

- **Cost saving:** ~$32-65/month per environment — substantial for a course project
- **Trade-off:** Nodes have public IPs. Mitigated by security groups which restrict
  all inbound traffic — no direct inbound allowed to nodes from internet
- **Security groups are the perimeter:** Must be treated as strictly as private subnet firewalls
- **Cross-SG rules required for Karpenter:** Karpenter-provisioned nodes and
  managed nodes are in the same public subnet but need explicit cross-SG ingress
  rules to communicate. These are managed by Terraform in
  `terraform/environments/{env}/main.tf`. Missing cross-SG rules cause pod
  networking failures between node types.
- **RDS in public subnet:** `publicly_accessible = false` ensures RDS is not
  reachable from the internet despite being in a public subnet. Only the EKS
  node security group can reach port 3306.
- In real production at scale: use private subnets + NAT Gateway for defense
  in depth and compliance requirements
