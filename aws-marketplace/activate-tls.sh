#!/usr/bin/env bash
set -euo pipefail

# OpenChoreo AWS Marketplace TLS Activation
# Runs inside CodeBuild during Phase 2 stack creation.
# Swaps self-signed certs for real ACME certs (Cloudflare or Route53 DNS-01).

# ── Helpers ──────────────────────────────────────────────────────────────────
log()  { echo "$(date +%H:%M:%S) [INFO]  $*"; }
warn() { echo "$(date +%H:%M:%S) [WARN]  $*" >&2; }
die()  { echo "$(date +%H:%M:%S) [FATAL] $*" >&2; exit 1; }

signal_success() {
  if [[ -n "${WAIT_CONDITION_URL:-}" ]]; then
    curl -s -X PUT "$WAIT_CONDITION_URL" \
      -H "Content-Type:" \
      -d "{\"Status\":\"SUCCESS\",\"Reason\":\"TLS activation complete\",\"UniqueId\":\"tls\",\"Data\":\"ok\"}"
  fi
}

signal_failure() {
  local exit_code=$?
  warn "TLS activation failed (exit code ${exit_code})"
  if [[ -n "${WAIT_CONDITION_URL:-}" ]]; then
    curl -s -X PUT "$WAIT_CONDITION_URL" \
      -H "Content-Type:" \
      -d "{\"Status\":\"FAILURE\",\"Reason\":\"TLS activation failed at line ${BASH_LINENO[0]} (exit ${exit_code})\",\"UniqueId\":\"tls\",\"Data\":\"failed\"}"
  fi
  exit "$exit_code"
}

trap signal_failure ERR

wait_cert() {
  local name="$1" ns="$2" timeout="${3:-600}"
  log "Waiting for certificate ${name} in ${ns} (timeout ${timeout}s)..."
  kubectl wait --for=condition=Ready "certificate/${name}" -n "${ns}" --timeout="${timeout}s"
}

# ── Required env vars (set by CodeBuild) ─────────────────────────────────────
: "${PHASE1_STACK_NAME:?}" "${AWS_REGION:?}" "${TLS_METHOD:?}" "${ADMIN_EMAIL:?}"

STACK_NAME="$PHASE1_STACK_NAME"

# ── Self-signed: nothing to do ───────────────────────────────────────────────
if [[ "$TLS_METHOD" == "self-signed" ]]; then
  log "TLS method is self-signed. No changes needed."
  signal_success
  exit 0
fi

# ── Step 1: Get Phase 1 stack outputs ────────────────────────────────────────
log "Step 1: Loading Phase 1 stack outputs..."

eval "$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" \
  --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' --output text | \
  awk -F'\t' 'NF==2 && $1 ~ /^[A-Za-z_][A-Za-z0-9_]*$/ {print "export "$1"=\""$2"\""}')"

export BASE_DOMAIN="$BaseDomain"

# ── Step 2: Configure kubectl ────────────────────────────────────────────────
log "Step 2: Configuring kubectl..."
aws eks update-kubeconfig --name "$STACK_NAME" --region "$AWS_REGION"
kubectl get nodes || die "Cannot connect to EKS cluster"

# ── Step 3: Create ACME ClusterIssuer ────────────────────────────────────────
log "Step 3: Creating ACME ClusterIssuer (method: ${TLS_METHOD})..."

if [[ "$TLS_METHOD" == "cloudflare" ]]; then
  : "${CLOUDFLARE_API_TOKEN:?Cloudflare API token required}"

  # Store token in Secrets Manager
  aws secretsmanager create-secret \
    --name "${STACK_NAME}/cloudflare/api-token" \
    --secret-string "{\"api-token\":\"${CLOUDFLARE_API_TOKEN}\"}" \
    --region "$AWS_REGION" 2>/dev/null || \
  aws secretsmanager update-secret \
    --secret-id "${STACK_NAME}/cloudflare/api-token" \
    --secret-string "{\"api-token\":\"${CLOUDFLARE_API_TOKEN}\"}" \
    --region "$AWS_REGION"

  # Create ExternalSecret for cert-manager
  kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: cloudflare-api-token
  namespace: cert-manager
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: cloudflare-api-token
  data:
    - secretKey: api-token
      remoteRef:
        key: ${STACK_NAME}/cloudflare/api-token
        property: api-token
EOF
  kubectl wait --for=condition=Ready externalsecret/cloudflare-api-token -n cert-manager --timeout=60s

  # Create ACME ClusterIssuer with Cloudflare DNS-01
  kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${ADMIN_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
    - dns01:
        cloudflare:
          apiTokenSecretRef:
            name: cloudflare-api-token
            key: api-token
      selector:
        dnsZones:
          - "${BASE_DOMAIN}"
EOF

elif [[ "$TLS_METHOD" == "route53" ]]; then
  : "${ROUTE53_HOSTED_ZONE_ID:?Route53 hosted zone ID required}"
  : "${CERT_MANAGER_ROUTE53_ROLE_ARN:?Route53 IRSA role ARN required}"

  # Annotate cert-manager service account with IRSA role
  kubectl annotate serviceaccount cert-manager \
    -n cert-manager \
    "eks.amazonaws.com/role-arn=${CERT_MANAGER_ROUTE53_ROLE_ARN}" \
    --overwrite

  # Restart cert-manager to pick up the IRSA annotation
  kubectl rollout restart deployment/cert-manager -n cert-manager
  kubectl rollout status deployment/cert-manager -n cert-manager --timeout=120s

  # Create ACME ClusterIssuer with Route53 DNS-01
  kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${ADMIN_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
    - dns01:
        route53:
          region: ${AWS_REGION}
          hostedZoneID: ${ROUTE53_HOSTED_ZONE_ID}
      selector:
        dnsZones:
          - "${BASE_DOMAIN}"
EOF
fi

# ── Step 4: Delete old self-signed Certificate CRs ──────────────────────────
log "Step 4: Deleting self-signed Certificate CRs..."

# Deleting the Certificate CR removes cert-manager's tracking but keeps the
# Secret intact. The new Certificate CR (same secretName) will overwrite it
# once ACME issuance completes.
kubectl delete certificate control-plane-tls -n openchoreo-control-plane 2>/dev/null || true
kubectl delete certificate data-plane-tls -n openchoreo-data-plane 2>/dev/null || true

# ── Step 5: Create new Certificate CRs with ACME issuer ─────────────────────
log "Step 5: Creating ACME Certificate CRs..."

kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: control-plane-tls
  namespace: openchoreo-control-plane
spec:
  secretName: control-plane-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - "console.${BASE_DOMAIN}"
    - "api.${BASE_DOMAIN}"
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: data-plane-tls
  namespace: openchoreo-data-plane
spec:
  secretName: data-plane-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - "*.apps.${BASE_DOMAIN}"
EOF

# ── Step 6: Wait for certificate issuance ────────────────────────────────────
log "Step 6: Waiting for ACME certificate issuance..."
wait_cert "control-plane-tls" "openchoreo-control-plane" 600
wait_cert "data-plane-tls" "openchoreo-data-plane" 600

log "TLS activation complete. Certificates issued by Let's Encrypt."
signal_success
