# ADR-0014: Karpenter for Node Autoscaling with Graviton Free Tier

**Status:** Accepted
**Date:** 2025

---

## Context

The platform needs node autoscaling — the ability to add nodes when workloads
increase and remove them when idle. Two approaches were evaluated:

1. **Cluster Autoscaler (CA)** — traditional Kubernetes node autoscaler,
   works with AWS Auto Scaling Groups
2. **Karpenter** — next-generation node autoscaler, provisions EC2 instances
   directly without ASGs

Additionally, AWS offers a **Graviton (ARM64) free trial** for `t4g` instance
types until December 2026, making ARM64 builds cost-free for this project.

---

## Decision

Use Karpenter v1.1.1 with `t4g.small` on-demand instances. Build all Docker
images for `linux/arm64` to run natively on Graviton.

**Karpenter NodePool configuration:**
```yaml
spec:
  template:
    spec:
      nodeClassRef:
        name: default
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["t4g.small"]
```

---

## Why Karpenter over Cluster Autoscaler

| Concern | Cluster Autoscaler | Karpenter |
|---------|-------------------|-----------|
| Provisioning speed | 3-5 min (ASG) | 30-60 sec (direct EC2) |
| Instance flexibility | ASG instance type only | Any instance type per NodePool |
| Bin packing | Limited | Optimized — fewer nodes needed |
| Node consolidation | Manual | Automatic (disruption budget aware) |
| AWS integration | via ASG | Direct EC2 API |
| Complexity | Lower | Higher (IRSA, SQS, EventBridge) |

Karpenter is the AWS-recommended approach for EKS autoscaling and is increasingly
the industry standard. Cluster Autoscaler is being deprecated for new projects.

---

## Why Graviton (ARM64)

- **Free until Dec 2026:** AWS Graviton free trial covers all `t4g` instance
  types — `t4g.small`, `t4g.medium`, `t4g.large`, etc.
- **Better price/performance:** Graviton3 delivers ~40% better price/performance
  than x86 equivalents when not on free tier
- **Spring Boot ARM64 support:** Spring Boot 3.x and JVM 17+ have full ARM64
  support — no application changes needed
- **Docker Buildx + QEMU:** CI pipeline uses `docker buildx` with QEMU emulation
  to cross-compile `linux/arm64` images on GitHub Actions x86 runners

---

## Implementation Details

### Karpenter IAM Requirements

Karpenter needs several AWS resources:
- **IRSA role** with EC2, SQS, EKS, IAM permissions
- **SQS queue** for spot interruption and health event notifications
- **EventBridge rules** to route EC2 events to SQS
- **EKS access entry** for Karpenter node role (separate from IRSA role)

All managed by `terraform/modules/karpenter/`.

### Cross-SG Rules (Critical)

Karpenter-provisioned nodes use the same `eks-node-sg` security group as
managed nodes. However, the managed node group creates its own security group
(`eks-managed-node-sg`) for node-to-node traffic. Without explicit cross-SG
rules between `eks-node-sg` and `eks-managed-node-sg`, Karpenter nodes cannot
communicate with managed nodes.

This caused pod networking failures in initial deployments. Fix applied in
`terraform/environments/{env}/main.tf`:

```hcl
# Allow Karpenter nodes → managed nodes
resource "aws_vpc_security_group_ingress_rule" "karpenter_to_managed" {
  security_group_id            = module.eks.managed_node_sg_id
  referenced_security_group_id = module.eks.node_sg_id
  ip_protocol                  = "-1"
}

# Allow managed nodes → Karpenter nodes
resource "aws_vpc_security_group_ingress_rule" "managed_to_karpenter" {
  security_group_id            = module.eks.node_sg_id
  referenced_security_group_id = module.eks.managed_node_sg_id
  ip_protocol                  = "-1"
}
```

### ARM64 Docker Builds

CI pipeline uses QEMU for cross-compilation:
```yaml
- uses: docker/setup-qemu-action@v3
  with:
    platforms: arm64
- uses: docker/setup-buildx-action@v3

- run: |
    ./mvnw clean install -P buildDocker \
      -Dcontainer.platform="linux/arm64" \
      -pl ${MODULE} -am
```

Local builds use `build-push-images.sh` which creates a `petclinic-builder`
buildx builder. After Docker Desktop restarts, the builder's bind mount
becomes stale. The script auto-detects and recreates the builder.

### Spot NodePool (Future)

`k8s/base/karpenter/nodepool-spot-dev.yaml` is prepared but NOT applied while
the Graviton free trial is active. After Dec 2026, apply it to enable Spot
instances (~70% cost saving vs on-demand):

```bash
kubectl apply -f k8s/base/karpenter/nodepool-spot-dev.yaml
```

---

## Consequences

**Positive:**
- Nodes provision in 30-60 seconds vs 3-5 minutes with Cluster Autoscaler
- `t4g` instances are free during Graviton trial — zero compute cost
- Industry-relevant: Karpenter is the modern AWS autoscaling approach
- ARM64 images are smaller and faster to pull
- Automatic node consolidation reduces idle costs

**Negative:**
- More complex setup: IRSA + SQS + EventBridge + EKS access entry
- Cross-SG rules must be explicitly added (non-obvious requirement)
- Docker buildx builder becomes stale after Docker Desktop restart
  (fixed in `build-push-images.sh` with auto-recreation)
- ARM64 builds require QEMU emulation on CI (slower than native x86 builds)
- Karpenter CRDs (NodePool, EC2NodeClass, NodeClaim) are new concepts
  not covered in standard Kubernetes training

## Alternatives Considered

**Cluster Autoscaler:** Simpler setup, well-documented. Rejected — Karpenter
is faster, more flexible, and is the AWS-recommended approach going forward.

**x86 instances:** No cross-compilation needed, simpler Docker builds.
Rejected — Graviton free trial makes ARM64 the obvious choice for cost.
Graviton also provides better performance per dollar after the free trial ends.

**Spot instances from day one:** Maximum cost saving. Rejected — Spot
interruptions would make development unstable. Spot NodePool prepared for
after the free trial expires (see `nodepool-spot-dev.yaml`).
