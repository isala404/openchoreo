#!/usr/bin/env bash
# No -e: cleanup must attempt every step even if earlier ones fail
set -uo pipefail

# OpenChoreo AWS Marketplace Cleanup
# Runs inside CodeBuild during CloudFormation stack deletion.
# Removes all Kubernetes resources so CF can cleanly delete the underlying infra.

# ── Helpers ──────────────────────────────────────────────────────────────────
log()  { echo "$(date +%H:%M:%S) [INFO]  $*"; }
warn() { echo "$(date +%H:%M:%S) [WARN]  $*" >&2; }

signal_cfn_response() {
  local status="${1:-SUCCESS}" reason="${2:-Cleanup complete}"
  if [[ -n "${CFN_RESPONSE_URL:-}" ]]; then
    local body
    body=$(cat <<EOFJ
{
  "Status": "${status}",
  "Reason": "${reason}",
  "PhysicalResourceId": "${CFN_PHYSICAL_ID:-cleanup}",
  "StackId": "${CFN_STACK_ID:-}",
  "RequestId": "${CFN_REQUEST_ID:-}",
  "LogicalResourceId": "${CFN_LOGICAL_ID:-TriggerBootstrap}"
}
EOFJ
)
    curl -s -X PUT "$CFN_RESPONSE_URL" -H "Content-Type:" -d "$body"
    log "Sent CFN response: ${status}"
  fi
}

# Always signal SUCCESS so CF can proceed with deleting infra resources.
# A FAILURE response would block stack deletion forever, which is worse than
# leaving some k8s resources behind (CF deletes the cluster anyway).
trap 'signal_cfn_response SUCCESS "Cleanup finished"' EXIT

# ── Required env vars (set by CodeBuild) ─────────────────────────────────────
: "${STACK_NAME:?}" "${AWS_REGION:?}"

# ── Step 1: Export CloudFormation outputs ────────────────────────────────────
log "Step 1: Exporting CloudFormation outputs..."

eval "$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" \
  --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' --output text 2>/dev/null | \
  awk -F'\t' 'NF==2 && $1 ~ /^[A-Za-z_][A-Za-z0-9_]*$/ {print "export "$1"=\""$2"\""}')" 2>/dev/null || true

# ── Step 2: Configure kubectl ────────────────────────────────────────────────
log "Step 2: Configuring kubectl..."
aws eks update-kubeconfig --name "$STACK_NAME" --region "$AWS_REGION" 2>/dev/null || true

# ── Step 3: Remove Kubernetes resources ──────────────────────────────────────
if kubectl cluster-info &>/dev/null; then
  log "Step 3: Removing Kubernetes resources..."

  kubectl delete dataplane,buildplane,observabilityplane --all -n default 2>/dev/null || true

  for MODULE in observability-tracing-opensearch observability-metrics-prometheus observability-logs-opensearch; do
    helm uninstall "$MODULE" -n openchoreo-observability-plane 2>/dev/null && log "Uninstalled ${MODULE}" || true
  done

  for RELEASE in openchoreo-observability-plane opensearch-operator openchoreo-build-plane openchoreo-data-plane openchoreo-control-plane; do
    NS="${RELEASE}"
    [[ "$RELEASE" == "opensearch-operator" ]] && NS="openchoreo-observability-plane"
    helm uninstall "$RELEASE" -n "$NS" 2>/dev/null && log "Uninstalled ${RELEASE}" || true
  done

  helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true
  helm uninstall kgateway -n openchoreo-control-plane 2>/dev/null || true
  helm uninstall kgateway-crds -n openchoreo-control-plane 2>/dev/null || true
  helm uninstall external-secrets -n external-secrets 2>/dev/null || true
  helm uninstall cert-manager -n cert-manager 2>/dev/null || true

  kubectl delete -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/experimental-install.yaml 2>/dev/null || true

  log "Waiting 60s for NLB cleanup..."
  sleep 60
else
  warn "Cannot connect to cluster. Skipping Kubernetes cleanup."
fi

# Clean up security groups created by AWS LBC (not removed by helm uninstall)
if [[ -n "${VpcId:-}" ]]; then
  for sg_id in $(aws ec2 describe-security-groups --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=${VpcId}" "Name=tag:elbv2.k8s.aws/cluster,Values=${STACK_NAME}" \
    --query 'SecurityGroups[*].GroupId' --output text 2>/dev/null || true); do
    aws ec2 delete-security-group --group-id "$sg_id" --region "$AWS_REGION" 2>/dev/null || true
    log "Deleted security group: ${sg_id}"
  done
  # Also delete SGs with k8s-tagged names that CF won't know about
  for sg_id in $(aws ec2 describe-security-groups --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=${VpcId}" "Name=group-name,Values=k8s-*" \
    --query 'SecurityGroups[*].GroupId' --output text 2>/dev/null || true); do
    aws ec2 delete-security-group --group-id "$sg_id" --region "$AWS_REGION" 2>/dev/null || true
    log "Deleted k8s security group: ${sg_id}"
  done
fi

# ── Step 4: Clean up manually-created AWS resources ──────────────────────────
log "Step 4: Cleaning up AWS resources..."

if [[ -n "${CognitoUserPoolId:-}" ]]; then
  BACKEND_CID=$(aws cognito-idp list-user-pool-clients \
    --user-pool-id "$CognitoUserPoolId" \
    --region "$AWS_REGION" \
    --query "UserPoolClients[?ClientName=='openchoreo-backstage-backend'].ClientId" \
    --output text 2>/dev/null || true)

  if [[ -n "$BACKEND_CID" ]]; then
    aws cognito-idp delete-user-pool-client \
      --user-pool-id "$CognitoUserPoolId" \
      --client-id "$BACKEND_CID" \
      --region "$AWS_REGION" 2>/dev/null || true
    log "Deleted backend Cognito client"
  fi

  aws cognito-idp delete-resource-server \
    --user-pool-id "$CognitoUserPoolId" \
    --identifier openchoreo-api \
    --region "$AWS_REGION" 2>/dev/null || true
fi

aws secretsmanager delete-secret \
  --secret-id "registry-push-secret" \
  --force-delete-without-recovery \
  --region "$AWS_REGION" 2>/dev/null || true

# Remove ESO inline policy for registry-push-secret
aws iam delete-role-policy \
  --role-name "${STACK_NAME}-eso" \
  --policy-name registry-push-secret-access \
  2>/dev/null || true

# Release secondary EIPs allocated at runtime for dual-AZ NLBs
for tag_name in "${STACK_NAME}-cp-eip-2" "${STACK_NAME}-dp-eip-2"; do
  EIP_ALLOC=$(aws ec2 describe-addresses --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=${tag_name}" \
    --query 'Addresses[0].AllocationId' --output text 2>/dev/null || true)
  if [[ -n "$EIP_ALLOC" && "$EIP_ALLOC" != "None" ]]; then
    aws ec2 release-address --allocation-id "$EIP_ALLOC" --region "$AWS_REGION" 2>/dev/null || true
    log "Released EIP: ${tag_name}"
  fi
done

# ── Step 5: Disable RDS deletion protection ──────────────────────────────────
log "Step 5: Disabling RDS deletion protection..."

DB_ID="${STACK_NAME}-db"
aws rds modify-db-instance \
  --db-instance-identifier "$DB_ID" \
  --no-deletion-protection --apply-immediately \
  --region "$AWS_REGION" 2>/dev/null || true
sleep 10

log "Cleanup complete. CloudFormation will now delete remaining resources."
