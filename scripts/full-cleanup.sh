#!/bin/bash
# ==========================================================
# full-cleanup.sh — Destroys ALL infrastructure for both
# dev and prod environments in the correct order.
#
# Usage:
#   ./scripts/full-cleanup.sh            # destroys both
#   ./scripts/full-cleanup.sh --env dev  # destroys dev only
#   ./scripts/full-cleanup.sh --env prod # destroys prod only
# ==========================================================
set -uo pipefail

# ── Disable all interactive prompts ──────────────────────────────────────────
export TF_IN_AUTOMATION=1
export PAGER=""
export TF_CLI_ARGS="-no-color"
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TARGET_ENV="both"
while [[ $# -gt 0 ]]; do
  case $1 in
    --env) TARGET_ENV="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

REGION="ap-south-1"

echo "=============================================="
echo " Full Cleanup — Target: ${TARGET_ENV}"
echo "=============================================="
echo ""
read -r -p " Type 'destroy' to confirm: " CONFIRM
if [ "${CONFIRM}" != "destroy" ]; then
  echo " Aborted."
  exit 1
fi

# ── Helper: read VPC ID from S3 state directly ───────────────────────────────
# Bypasses terraform output which hangs due to TLS provider shutdown bug.
get_vpc_id_from_state() {
  local ENV="$1"
  local STATE_FILE="/tmp/tfstate-${ENV}.json"
  local BACKEND_CONFIG="${REPO_ROOT}/config/backend-${ENV}.hcl"

  if [ ! -f "${STATE_FILE}" ]; then
    if [ ! -f "${BACKEND_CONFIG}" ]; then
      echo ""
      return
    fi
    S3_BUCKET=$(grep "^bucket" "${BACKEND_CONFIG}" \
      | sed 's/.*=\s*//' | tr -d '"' | tr -d ' ')
    S3_KEY=$(grep "^key" "${BACKEND_CONFIG}" \
      | sed 's/.*=\s*//' | tr -d '"' | tr -d ' ')
    S3_REGION=$(grep "^region" "${BACKEND_CONFIG}" \
      | sed 's/.*=\s*//' | tr -d '"' | tr -d ' ')
    aws s3 cp "s3://${S3_BUCKET}/${S3_KEY}" "${STATE_FILE}" \
      --region "${S3_REGION}" --quiet 2>/dev/null || true
  fi

  if [ -f "${STATE_FILE}" ]; then
    python3 -c "
import json
with open('${STATE_FILE}') as f:
    state = json.load(f)
print(state.get('outputs',{}).get('vpc_id',{}).get('value',''))
" 2>/dev/null || echo ""
  else
    echo ""
  fi
}

# ── Helper: force delete all SGs in a VPC ────────────────────────────────────
delete_vpc_security_groups() {
  local VPC_ID="$1"
  echo "  Revoking and deleting security groups in ${VPC_ID}..."

  ALL_SGS=$(aws ec2 describe-security-groups \
    --region "${REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" \
    --output text 2>/dev/null || echo "")

  for SG in ${ALL_SGS}; do
    INGRESS=$(aws ec2 describe-security-groups \
      --group-ids "${SG}" --region "${REGION}" \
      --query "SecurityGroups[0].IpPermissions" \
      --output json 2>/dev/null || echo "[]")
    if [ "${INGRESS}" != "[]" ] && [ -n "${INGRESS}" ]; then
      aws ec2 revoke-security-group-ingress \
        --group-id "${SG}" \
        --ip-permissions "${INGRESS}" \
        --region "${REGION}" 2>/dev/null || true
    fi

    EGRESS=$(aws ec2 describe-security-groups \
      --group-ids "${SG}" --region "${REGION}" \
      --query "SecurityGroups[0].IpPermissionsEgress" \
      --output json 2>/dev/null || echo "[]")
    if [ "${EGRESS}" != "[]" ] && [ -n "${EGRESS}" ]; then
      aws ec2 revoke-security-group-egress \
        --group-id "${SG}" \
        --ip-permissions "${EGRESS}" \
        --region "${REGION}" 2>/dev/null || true
    fi
  done

  sleep 5

  for SG in ${ALL_SGS}; do
    aws ec2 delete-security-group \
      --group-id "${SG}" \
      --region "${REGION}" 2>/dev/null && \
      echo "  ✅ Deleted SG: ${SG}" || \
      echo "  ⚠️  Could not delete SG: ${SG}"
  done
}

# ── Helper: force delete a VPC and all its dependencies ──────────────────────
force_delete_vpc() {
  local VPC_ID="$1"
  echo "  Force deleting VPC: ${VPC_ID}..."

  for SUBNET in $(aws ec2 describe-subnets \
    --region "${REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "Subnets[].SubnetId" \
    --output text 2>/dev/null); do
    aws ec2 delete-subnet \
      --subnet-id "${SUBNET}" \
      --region "${REGION}" 2>/dev/null && \
      echo "  ✅ Deleted subnet: ${SUBNET}" || true
  done

  for IGW in $(aws ec2 describe-internet-gateways \
    --region "${REGION}" \
    --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
    --query "InternetGateways[].InternetGatewayId" \
    --output text 2>/dev/null); do
    aws ec2 detach-internet-gateway \
      --internet-gateway-id "${IGW}" \
      --vpc-id "${VPC_ID}" \
      --region "${REGION}" 2>/dev/null || true
    aws ec2 delete-internet-gateway \
      --internet-gateway-id "${IGW}" \
      --region "${REGION}" 2>/dev/null && \
      echo "  ✅ Deleted IGW: ${IGW}" || true
  done

  for RT in $(aws ec2 describe-route-tables \
    --region "${REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "RouteTables[].RouteTableId" \
    --output text 2>/dev/null); do
    aws ec2 delete-route-table \
      --route-table-id "${RT}" \
      --region "${REGION}" 2>/dev/null && \
      echo "  ✅ Deleted RT: ${RT}" || true
  done

  delete_vpc_security_groups "${VPC_ID}"

  aws ec2 delete-vpc \
    --vpc-id "${VPC_ID}" \
    --region "${REGION}" 2>/dev/null && \
    echo "  ✅ Deleted VPC: ${VPC_ID}" || \
    echo "  ⚠️  Could not delete VPC: ${VPC_ID}"
}

# ── Helper: cleanup one environment ──────────────────────────────────────────
cleanup_env() {
  local ENV="$1"
  local TF_DIR="${REPO_ROOT}/terraform/environments/${ENV}"

  echo ""
  echo "=============================================="
  echo " Cleaning up ${ENV} environment"
  echo "=============================================="

  # Get VPC ID from S3 state — bypasses terraform output which hangs
  VPC_ID=$(get_vpc_id_from_state "${ENV}")
  echo "  VPC ID: ${VPC_ID:-NOT FOUND}"

  # ── Step 1: kubectl cleanup ───────────────────────────────────────────────
  echo ""
  echo "[1/4] Cleaning up Kubernetes resources..."
  if aws eks update-kubeconfig \
    --name "petclinic-${ENV}" \
    --region "${REGION}" 2>/dev/null && \
    kubectl cluster-info &>/dev/null 2>&1; then

    echo "  Deleting ArgoCD applications..."
    kubectl delete applications --all -n argocd \
      --timeout=60s 2>/dev/null || true
    sleep 10

    echo "  Deleting ingresses..."
    for NS in "petclinic-${ENV}" monitoring argocd tracing; do
      kubectl delete ingress --all -n "${NS}" \
        2>/dev/null || true
    done
    echo "  Waiting 90s for ALB Controller to release ALBs..."
    sleep 90

    echo "  Deleting Karpenter resources..."
    kubectl delete nodepool --all 2>/dev/null || true
    kubectl delete ec2nodeclass --all 2>/dev/null || true
    sleep 30

    echo "  Uninstalling Helm releases..."
    for RELEASE_NS in \
      "karpenter:kube-system" \
      "aws-load-balancer-controller:kube-system" \
      "prometheus:monitoring" \
      "grafana:monitoring" \
      "loki:monitoring" \
      "fluent-bit:monitoring" \
      "external-secrets:external-secrets" \
      "argocd:argocd"; do
      RELEASE="${RELEASE_NS%%:*}"
      NS="${RELEASE_NS##*:}"
      helm uninstall "${RELEASE}" -n "${NS}" 2>/dev/null && \
        echo "  ✅ ${RELEASE}" || true
    done
    sleep 20
  else
    echo "  ⚠️  Could not connect to cluster — skipping K8s cleanup"
  fi

  # ── Step 2: Delete ALBs and target groups ────────────────────────────────
  echo ""
  echo "[2/4] Cleaning up ALBs and target groups..."
  if [ -n "${VPC_ID}" ]; then
    for ALB in $(aws elbv2 describe-load-balancers \
      --region "${REGION}" \
      --query "LoadBalancers[?VpcId=='${VPC_ID}'].LoadBalancerArn" \
      --output text 2>/dev/null); do
      aws elbv2 delete-load-balancer \
        --load-balancer-arn "${ALB}" \
        --region "${REGION}" 2>/dev/null && \
        echo "  ✅ Deleted ALB: ${ALB}" || true
    done
    sleep 30

    for TG in $(aws elbv2 describe-target-groups \
      --region "${REGION}" \
      --query "TargetGroups[?VpcId=='${VPC_ID}'].TargetGroupArn" \
      --output text 2>/dev/null); do
      aws elbv2 delete-target-group \
        --target-group-arn "${TG}" \
        --region "${REGION}" 2>/dev/null && \
        echo "  ✅ Deleted TG: ${TG}" || true
    done
  fi

  for TG in $(aws elbv2 describe-target-groups \
    --region "${REGION}" \
    --query "TargetGroups[?starts_with(TargetGroupName,'k8s-')].TargetGroupArn" \
    --output text 2>/dev/null); do
    aws elbv2 delete-target-group \
      --target-group-arn "${TG}" \
      --region "${REGION}" 2>/dev/null && \
      echo "  ✅ Deleted orphaned TG: ${TG}" || true
  done

  # ── Step 3: Terminate EC2 instances ──────────────────────────────────────
  echo ""
  echo "[3/4] Terminating EC2 instances..."
  if [ -n "${VPC_ID}" ]; then
    INSTANCES=$(aws ec2 describe-instances \
      --region "${REGION}" \
      --filters \
        "Name=vpc-id,Values=${VPC_ID}" \
        "Name=instance-state-name,Values=pending,running,stopping,shutting-down" \
      --query "Reservations[].Instances[].InstanceId" \
      --output text 2>/dev/null || echo "")
    if [ -n "${INSTANCES}" ] && [ "${INSTANCES}" != "None" ]; then
      aws ec2 terminate-instances \
        --instance-ids ${INSTANCES} \
        --region "${REGION}" 2>/dev/null || true
      echo "  Waiting for instances to terminate..."
      aws ec2 wait instance-terminated \
        --instance-ids ${INSTANCES} \
        --region "${REGION}" 2>/dev/null || true
      echo "  ✅ Instances terminated"
    else
      echo "  ✅ No instances to terminate"
    fi
  fi

  # ── Step 4: Run pre-destroy then terraform destroy ───────────────────────
  echo ""
  echo "[4/4] Terraform destroy for ${ENV}..."
  "${SCRIPT_DIR}/pre-destroy.sh" --env "${ENV}" 2>/dev/null || true

  if [ -d "${TF_DIR}/.terraform" ]; then
    cd "${TF_DIR}"
    TF_IN_AUTOMATION=1 terraform destroy -auto-approve 2>&1 | tail -10
    cd "${REPO_ROOT}"
    echo "  ✅ Terraform destroy complete"
  fi

  # ── Post-destroy: force cleanup any remaining VPC resources ──────────────
  if [ -n "${VPC_ID}" ]; then
    echo ""
    echo "  Post-destroy force cleanup for VPC ${VPC_ID}..."
    force_delete_vpc "${VPC_ID}" 2>/dev/null || true
  fi

  # ── Delete Secrets Manager secrets ───────────────────────────────────────
  echo ""
  echo "  Deleting Secrets Manager secrets..."
  for SECRET in \
    "petclinic/${ENV}/rds-credentials" \
    "petclinic/${ENV}/openai-api-key" \
    "petclinic/${ENV}/grafana-credentials" \
    "petclinic/${ENV}/alertmanager-email"; do
    aws secretsmanager delete-secret \
      --secret-id "${SECRET}" \
      --force-delete-without-recovery \
      --region "${REGION}" 2>/dev/null && \
      echo "  ✅ Deleted secret: ${SECRET}" || true
  done

  # ── Clean up local state cache ────────────────────────────────────────────
  # Remove cached S3 state files so next deploy reads fresh state
  rm -f "/tmp/tfstate-${ENV}.json"
  echo "  ✅ Cleared local state cache for ${ENV}"

  echo ""
  echo "  ✅ ${ENV} cleanup complete"
}

# ── Run cleanup ───────────────────────────────────────────────────────────────
if [ "${TARGET_ENV}" = "both" ] || [ "${TARGET_ENV}" = "prod" ]; then
  cleanup_env "prod"
fi
if [ "${TARGET_ENV}" = "both" ] || [ "${TARGET_ENV}" = "dev" ]; then
  cleanup_env "dev"
fi

# ── Final verification ────────────────────────────────────────────────────────
echo ""
echo "=============================================="
echo " Final Verification"
echo "=============================================="

echo ""
echo "=== EKS Clusters ==="
aws eks list-clusters --region "${REGION}" --output table

echo ""
echo "=== EC2 Instances ==="
aws ec2 describe-instances \
  --region "${REGION}" \
  --filters "Name=instance-state-name,Values=running,pending" \
  --query "Reservations[].Instances[].[InstanceId,InstanceType]" \
  --output table 2>/dev/null || echo "None"

echo ""
echo "=== RDS Instances ==="
aws rds describe-db-instances \
  --region "${REGION}" \
  --query "DBInstances[].[DBInstanceIdentifier,DBInstanceStatus]" \
  --output table 2>/dev/null || echo "None"

echo ""
echo "=== Load Balancers ==="
aws elbv2 describe-load-balancers \
  --region "${REGION}" \
  --query "LoadBalancers[].[LoadBalancerName,State.Code]" \
  --output table 2>/dev/null || echo "None"

echo ""
echo "=== Target Groups (k8s-*) ==="
aws elbv2 describe-target-groups \
  --region "${REGION}" \
  --query "TargetGroups[?starts_with(TargetGroupName,'k8s-')].TargetGroupName" \
  --output table 2>/dev/null || echo "None"

echo ""
echo "=== VPCs (only default should remain) ==="
aws ec2 describe-vpcs \
  --region "${REGION}" \
  --query "Vpcs[].[VpcId,IsDefault,Tags[?Key=='Name'].Value|[0]]" \
  --output table

echo ""
echo "=== Secrets (petclinic) ==="
aws secretsmanager list-secrets \
  --region "${REGION}" \
  --query "SecretList[?contains(Name,'petclinic')].[Name]" \
  --output table 2>/dev/null || echo "None"

echo ""
echo "=== Security Groups (non-default) ==="
aws ec2 describe-security-groups \
  --region "${REGION}" \
  --query "SecurityGroups[?GroupName!='default'].[GroupId,GroupName,VpcId]" \
  --output table 2>/dev/null || echo "None"

echo ""
echo "=== NAT Gateways ==="
aws ec2 describe-nat-gateways \
  --region "${REGION}" \
  --filter "Name=state,Values=available,pending" \
  --query "NatGateways[].[NatGatewayId,State]" \
  --output table 2>/dev/null || echo "None"

echo ""
echo "=============================================="
echo " Cleanup complete!"
echo "=============================================="
