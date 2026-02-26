#!/usr/bin/env bash
set -euo pipefail

# OpenChoreo AWS Marketplace Bootstrap
# Runs inside CodeBuild after CloudFormation creates the base infrastructure.
# Installs all Kubernetes components with self-signed TLS certificates.

# ── Helpers ──────────────────────────────────────────────────────────────────
log()  { echo "$(date +%H:%M:%S) [INFO]  $*"; }
warn() { echo "$(date +%H:%M:%S) [WARN]  $*" >&2; }
die()  { echo "$(date +%H:%M:%S) [FATAL] $*" >&2; exit 1; }

signal_success() {
  if [[ -n "${WAIT_CONDITION_URL:-}" ]]; then
    curl -s -X PUT "$WAIT_CONDITION_URL" \
      -H "Content-Type:" \
      -d "{\"Status\":\"SUCCESS\",\"Reason\":\"Bootstrap complete\",\"UniqueId\":\"bootstrap\",\"Data\":\"ok\"}"
  fi
}

signal_failure() {
  local exit_code=$?
  warn "Bootstrap failed (exit code ${exit_code})"
  if [[ -n "${WAIT_CONDITION_URL:-}" ]]; then
    curl -s -X PUT "$WAIT_CONDITION_URL" \
      -H "Content-Type:" \
      -d "{\"Status\":\"FAILURE\",\"Reason\":\"Bootstrap failed at line ${BASH_LINENO[0]:-unknown} (exit ${exit_code})\",\"UniqueId\":\"bootstrap\",\"Data\":\"failed\"}" || true
  fi
  exit "$exit_code"
}

# EXIT catches all failures including set -u unbound variables (ERR doesn't)
trap 'if [[ $? -ne 0 ]]; then signal_failure; fi' EXIT
trap signal_failure ERR

wait_cert() {
  local name="$1" ns="$2" timeout="${3:-600}"
  log "Waiting for certificate ${name} in ${ns} (timeout ${timeout}s)..."
  kubectl wait --for=condition=Ready "certificate/${name}" -n "${ns}" --timeout="${timeout}s"
}

# ── Required env vars (set by CodeBuild from CloudFormation) ─────────────────
: "${STACK_NAME:?}" "${AWS_REGION:?}" "${OPENCHOREO_VERSION:?}"
: "${BaseDomain:?}" "${ClusterName:?}" "${VpcId:?}" "${PublicSubnets:?}"
: "${DBEndpoint:?}" "${ECRUri:?}" "${CognitoUserPoolId:?}"
: "${CognitoIssuerUrl:?}" "${CognitoJwksUrl:?}" "${CognitoDomainUrl:?}"
: "${BackstageClientId:?}" "${CLIClientId:?}"
: "${CPEIPAllocationId:?}" "${CPEIPAddress:?}"
: "${DPEIPAllocationId:?}" "${DPEIPAddress:?}"
: "${ESORoleArn:?}" "${LBCRoleArn:?}" "${BuildRoleArn:?}"

export RELEASE_BRANCH="release-v${OPENCHOREO_VERSION%.*}"
export BASE_DOMAIN="$BaseDomain"

log "Cluster: $ClusterName | CP IP: $CPEIPAddress | DP IP: $DPEIPAddress"

# ── Step 2: Configure kubectl ────────────────────────────────────────────────
log "Step 2: Configuring kubectl..."
aws eks update-kubeconfig --name "$STACK_NAME" --region "$AWS_REGION"
kubectl get nodes || die "Cannot connect to EKS cluster"

kubectl patch sc gp2 -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' 2>/dev/null || true

# ── Step 3: Create namespaces ────────────────────────────────────────────────
log "Step 3: Creating namespaces..."
for NS in openchoreo-control-plane openchoreo-data-plane openchoreo-build-plane openchoreo-observability-plane; do
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
done

# ── Step 4: Gateway API CRDs ────────────────────────────────────────────────
log "Step 4: Installing Gateway API CRDs..."
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/experimental-install.yaml

# ── Step 5: cert-manager ────────────────────────────────────────────────────
log "Step 5: Installing cert-manager..."
helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --namespace cert-manager \
  --version v1.19.2 \
  --create-namespace \
  --set crds.enabled=true \
  --wait --timeout 180s

# ── Step 6: External Secrets Operator ────────────────────────────────────────
log "Step 6: Installing External Secrets Operator..."
helm upgrade --install external-secrets oci://ghcr.io/external-secrets/charts/external-secrets \
  --namespace external-secrets \
  --version 1.3.2 \
  --create-namespace \
  --set installCRDs=true \
  --set serviceAccount.name=external-secrets-sa \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${ESORoleArn}" \
  --wait --timeout 180s

# ── Step 7: kgateway ────────────────────────────────────────────────────────
log "Step 7: Installing kgateway..."
KGATEWAY_CHART="oci://cr.kgateway.dev/kgateway-dev/charts"

helm upgrade --install kgateway-crds "${KGATEWAY_CHART}/kgateway-crds" \
  --namespace openchoreo-control-plane \
  --version v2.2.1 \
  --wait --timeout 300s

helm upgrade --install kgateway "${KGATEWAY_CHART}/kgateway" \
  --namespace openchoreo-control-plane \
  --version v2.2.1 \
  --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true \
  --wait --timeout 300s

# ── Step 8: AWS Load Balancer Controller ─────────────────────────────────────
log "Step 8: Installing AWS Load Balancer Controller..."
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update eks
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version 3.0.0 \
  --namespace kube-system \
  -f - <<EOF
clusterName: ${STACK_NAME}
serviceAccount:
  create: true
  name: aws-load-balancer-controller
  annotations:
    eks.amazonaws.com/role-arn: "${LBCRoleArn}"
region: ${AWS_REGION}
vpcId: ${VpcId}
EOF
kubectl wait --for=condition=Available deployment/aws-load-balancer-controller -n kube-system --timeout=180s

# ── Step 9: ClusterSecretStores ──────────────────────────────────────────────
log "Step 9: Creating ClusterSecretStores..."
kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: ${AWS_REGION}
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa
            namespace: external-secrets
EOF
sleep 5
kubectl wait --for=condition=Ready clustersecretstore/aws-secrets-manager --timeout=60s

# Build plane controller hardcodes 'default' as the store name for ExternalSecrets
kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: default
spec:
  provider:
    aws:
      service: SecretsManager
      region: ${AWS_REGION}
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa
            namespace: external-secrets
EOF
kubectl wait --for=condition=Ready clustersecretstore/default --timeout=60s

# ── Step 10: Self-signed CA chain ────────────────────────────────────────────
log "Step 10: Creating self-signed CA chain..."

kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-bootstrap
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: openchoreo-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: openchoreo-ca
  secretName: openchoreo-ca-keypair
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned-bootstrap
    kind: ClusterIssuer
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: openchoreo-ca
spec:
  ca:
    secretName: openchoreo-ca-keypair
EOF

wait_cert "openchoreo-ca" "cert-manager" 120

# ── Step 11: Sync Cognito client secrets ─────────────────────────────────────
log "Step 11: Syncing Cognito client secrets..."

BACKSTAGE_CLIENT_SECRET=$(aws cognito-idp describe-user-pool-client \
  --user-pool-id "$CognitoUserPoolId" \
  --client-id "$BackstageClientId" \
  --query 'UserPoolClient.ClientSecret' \
  --output text --region "$AWS_REGION")

aws secretsmanager update-secret \
  --secret-id "${STACK_NAME}/cognito/backstage-client" \
  --secret-string "{\"client_id\":\"${BackstageClientId}\",\"client_secret\":\"${BACKSTAGE_CLIENT_SECRET}\"}" \
  --region "$AWS_REGION"

aws cognito-idp create-resource-server \
  --user-pool-id "$CognitoUserPoolId" \
  --identifier openchoreo-api \
  --name "OpenChoreo API" \
  --scopes ScopeName=internal,ScopeDescription="Internal API access" \
  --region "$AWS_REGION" 2>/dev/null || true

BACKEND_CLIENT=$(aws cognito-idp create-user-pool-client \
  --user-pool-id "$CognitoUserPoolId" \
  --client-name "openchoreo-backstage-backend" \
  --generate-secret \
  --allowed-o-auth-flows client_credentials \
  --allowed-o-auth-scopes openchoreo-api/internal \
  --allowed-o-auth-flows-user-pool-client \
  --region "$AWS_REGION" 2>/dev/null || \
  aws cognito-idp describe-user-pool-client \
    --user-pool-id "$CognitoUserPoolId" \
    --client-id "$(aws cognito-idp list-user-pool-clients \
      --user-pool-id "$CognitoUserPoolId" \
      --region "$AWS_REGION" \
      --query "UserPoolClients[?ClientName=='openchoreo-backstage-backend'].ClientId" \
      --output text)" \
    --region "$AWS_REGION")

export BACKEND_CLIENT_ID=$(echo "$BACKEND_CLIENT" | jq -r '.UserPoolClient.ClientId')
log "Backend client ID: ${BACKEND_CLIENT_ID}"

# ── Step 12: Setup RDS database ──────────────────────────────────────────────
log "Step 12: Setting up RDS database..."

kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: db-master-credentials
  namespace: openchoreo-control-plane
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: db-master-credentials
  data:
    - secretKey: username
      remoteRef:
        key: ${STACK_NAME}/database/master
        property: username
    - secretKey: password
      remoteRef:
        key: ${STACK_NAME}/database/master
        property: password
    - secretKey: backstage-password
      remoteRef:
        key: ${STACK_NAME}/database/backstage
        property: password
EOF
kubectl wait --for=condition=Ready externalsecret/db-master-credentials -n openchoreo-control-plane --timeout=60s

kubectl delete job db-setup -n openchoreo-control-plane 2>/dev/null || true
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: db-setup
  namespace: openchoreo-control-plane
spec:
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: db-setup
        image: postgres:17-alpine
        env:
        - name: PGHOST
          value: "${DBEndpoint}"
        - name: PGUSER
          valueFrom:
            secretKeyRef:
              name: db-master-credentials
              key: username
        - name: PGPASSWORD
          valueFrom:
            secretKeyRef:
              name: db-master-credentials
              key: password
        - name: BACKSTAGE_PASSWORD
          valueFrom:
            secretKeyRef:
              name: db-master-credentials
              key: backstage-password
        command: ["/bin/sh", "-c"]
        args:
        - |
          set -e
          echo "SELECT 'CREATE DATABASE backstage_db' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'backstage_db') \gexec" | psql -d postgres
          psql -d postgres -c "DO \\\$\\\$ BEGIN CREATE USER backstage_user; EXCEPTION WHEN duplicate_object THEN NULL; END \\\$\\\$;"
          psql -d postgres -c "ALTER USER backstage_user WITH PASSWORD '\${BACKSTAGE_PASSWORD}';"
          psql -d postgres -c "GRANT ALL PRIVILEGES ON DATABASE backstage_db TO backstage_user;"
          psql -d backstage_db -c "GRANT ALL ON SCHEMA public TO backstage_user;"
          psql -d postgres -c "ALTER USER backstage_user CREATEDB;"
          echo "Database setup complete."
EOF
kubectl wait --for=condition=Complete job/db-setup -n openchoreo-control-plane --timeout=180s
log "Database setup complete."

# ── Step 13: Backstage ExternalSecret ────────────────────────────────────────
log "Step 13: Creating Backstage ExternalSecret..."

kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: backstage-secrets
  namespace: openchoreo-control-plane
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: openchoreo-backstage-secrets
    template:
      data:
        backend-secret: "{{ .backend_secret }}"
        client-secret: "{{ .client_secret }}"
        postgres-host: "${DBEndpoint}"
        postgres-port: "5432"
        postgres-user: "backstage_user"
        postgres-password: "{{ .postgres_password }}"
        postgres-db: "backstage_db"
        jenkins-api-key: "unused"
  data:
    - secretKey: backend_secret
      remoteRef:
        key: ${STACK_NAME}/backstage/backend-secret
        property: backend-secret
    - secretKey: client_secret
      remoteRef:
        key: ${STACK_NAME}/cognito/backstage-client
        property: client_secret
    - secretKey: postgres_password
      remoteRef:
        key: ${STACK_NAME}/database/backstage
        property: password
EOF
kubectl wait --for=condition=Ready externalsecret/backstage-secrets -n openchoreo-control-plane --timeout=60s

# ── Step 14: Install Control Plane ───────────────────────────────────────────
log "Step 14: Installing Control Plane..."

export COGNITO_ISSUER_URL=$CognitoIssuerUrl
export COGNITO_JWKS_URL=$CognitoJwksUrl
export COGNITO_DOMAIN_URL=$CognitoDomainUrl
export CLI_CLIENT_ID=$CLIClientId
export BACKSTAGE_CLIENT_ID=$BackstageClientId
export PUBLIC_SUBNETS="$PublicSubnets"

# Allocate secondary EIPs for dual-AZ NLB coverage (NLB needs one EIP per AZ)
FIRST_SUBNET=$(echo "$PublicSubnets" | cut -d, -f1)
FIRST_SUBNET_AZ=$(aws ec2 describe-subnets --subnet-ids "$FIRST_SUBNET" --region "$AWS_REGION" --query 'Subnets[0].AvailabilityZone' --output text)

CP_EIP2=$(aws ec2 allocate-address --domain vpc --region "$AWS_REGION" --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${STACK_NAME}-cp-eip-2}]" --output json 2>/dev/null || true)
CP_EIP2_ALLOC=$(echo "$CP_EIP2" | jq -r '.AllocationId // empty')
if [[ -z "$CP_EIP2_ALLOC" ]]; then
  warn "Could not allocate CP EIP2, using single-AZ NLB"
  CP_EIP_ALLOCATIONS="$CPEIPAllocationId"
  CP_SUBNETS="$FIRST_SUBNET"
else
  CP_EIP_ALLOCATIONS="${CPEIPAllocationId},${CP_EIP2_ALLOC}"
  CP_SUBNETS="$PublicSubnets"
fi

DP_EIP2=$(aws ec2 allocate-address --domain vpc --region "$AWS_REGION" --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${STACK_NAME}-dp-eip-2}]" --output json 2>/dev/null || true)
DP_EIP2_ALLOC=$(echo "$DP_EIP2" | jq -r '.AllocationId // empty')
if [[ -z "$DP_EIP2_ALLOC" ]]; then
  warn "Could not allocate DP EIP2, using single-AZ NLB"
  DP_EIP_ALLOCATIONS="$DPEIPAllocationId"
  DP_SUBNETS="$FIRST_SUBNET"
else
  DP_EIP_ALLOCATIONS="${DPEIPAllocationId},${DP_EIP2_ALLOC}"
  DP_SUBNETS="$PublicSubnets"
fi

helm upgrade --install openchoreo-control-plane \
  oci://ghcr.io/openchoreo/helm-charts/openchoreo-control-plane \
  --namespace openchoreo-control-plane \
  --version "$OPENCHOREO_VERSION" \
  --timeout 10m \
  -f - <<EOF
security:
  oidc:
    issuer: "${COGNITO_ISSUER_URL}"
    wellKnownEndpoint: "${COGNITO_ISSUER_URL}/.well-known/openid-configuration"
    jwksUrl: "${COGNITO_JWKS_URL}"
    authorizationUrl: "${COGNITO_DOMAIN_URL}/oauth2/authorize"
    tokenUrl: "${COGNITO_DOMAIN_URL}/oauth2/token"
    externalClients:
      - name: cli
        client_id: "${CLI_CLIENT_ID}"
        scopes:
          - "openid"
          - "profile"
          - "email"

openchoreoApi:
  http:
    hostnames:
      - "api.${BASE_DOMAIN}"
  config:
    server:
      publicUrl: "https://api.${BASE_DOMAIN}"
    security:
      subjects:
        user:
          mechanisms:
            jwt:
              entitlement:
                claim: "cognito:groups"
      authorization:
        bootstrap:
          mappings:
            - name: super-admin-binding
              roleRef: {name: super-admin}
              entitlement: {claim: "cognito:groups", value: admin}
              effect: allow
            - name: backstage-catalog-reader-binding
              roleRef: {name: backstage-catalog-reader}
              entitlement: {claim: sub, value: "${BACKEND_CLIENT_ID}"}
              effect: allow

gateway:
  infrastructure:
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-type: external
      service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
      service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
      service.beta.kubernetes.io/aws-load-balancer-eip-allocations: "${CP_EIP_ALLOCATIONS}"
      service.beta.kubernetes.io/aws-load-balancer-subnets: "${CP_SUBNETS}"
      service.beta.kubernetes.io/aws-load-balancer-attributes: load_balancing.cross_zone.enabled=true
  tls:
    hostname: "*.${BASE_DOMAIN}"
    certificateRefs:
      - name: control-plane-tls

backstage:
  secretName: openchoreo-backstage-secrets
  baseUrl: "https://console.${BASE_DOMAIN}"
  http:
    hostnames:
      - "console.${BASE_DOMAIN}"
  auth:
    clientId: ${BACKSTAGE_CLIENT_ID}
  database:
    type: postgresql
    postgresql:
      ssl: true
  extraEnv:
    - name: NODE_TLS_REJECT_UNAUTHORIZED
      value: "0"
EOF

# Backstage CI config with backend client credentials
BACKEND_CLIENT_SECRET=$(aws cognito-idp describe-user-pool-client \
  --user-pool-id "$CognitoUserPoolId" \
  --client-id "$BACKEND_CLIENT_ID" \
  --query 'UserPoolClient.ClientSecret' \
  --output text --region "$AWS_REGION")

kubectl create configmap backstage-ci-config \
  -n openchoreo-control-plane \
  --from-literal=app-config.ci.yaml="$(cat <<CIEOF
jenkins:
  baseUrl: \${JENKINS_BASE_URL}
  username: \${JENKINS_USERNAME}
  apiKey: \${JENKINS_API_KEY}

openchoreo:
  auth:
    clientId: "${BACKEND_CLIENT_ID}"
    clientSecret: "${BACKEND_CLIENT_SECRET}"
    tokenUrl: "${CognitoDomainUrl}/oauth2/token"
    scopes:
      - "openchoreo-api/internal"
CIEOF
)" --dry-run=client -o yaml | kubectl apply -f -

# subPath mounts don't auto-update, so restart backstage to pick up the new config
kubectl rollout restart deployment/backstage -n openchoreo-control-plane
kubectl rollout status deployment/backstage -n openchoreo-control-plane --timeout=120s

# ── Step 15: Self-signed TLS certificates ────────────────────────────────────
log "Step 15: Creating self-signed TLS certificates..."

kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: control-plane-tls
  namespace: openchoreo-control-plane
spec:
  secretName: control-plane-tls
  issuerRef:
    name: openchoreo-ca
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
    name: openchoreo-ca
    kind: ClusterIssuer
  dnsNames:
    - "*.apps.${BASE_DOMAIN}"
EOF

wait_cert "control-plane-tls" "openchoreo-control-plane" 120
wait_cert "data-plane-tls" "openchoreo-data-plane" 120

# ── Step 16: Copy cluster-gateway CA ─────────────────────────────────────────
log "Step 16: Copying cluster-gateway CA..."

for i in $(seq 1 60); do
  if kubectl get secret cluster-gateway-ca -n openchoreo-control-plane &>/dev/null; then
    break
  fi
  sleep 10
done

CA_DATA=$(kubectl get secret cluster-gateway-ca -n openchoreo-control-plane -o jsonpath='{.data.ca\.crt}' | base64 -d)

for NS in openchoreo-data-plane openchoreo-build-plane openchoreo-observability-plane; do
  kubectl create configmap cluster-gateway-ca -n "$NS" --from-literal=ca.crt="$CA_DATA" --dry-run=client -o yaml | kubectl apply -f -
done

# ── Step 17: Install Data Plane ──────────────────────────────────────────────
log "Step 17: Installing Data Plane..."

helm upgrade --install openchoreo-data-plane \
  oci://ghcr.io/openchoreo/helm-charts/openchoreo-data-plane \
  --namespace openchoreo-data-plane \
  --version "$OPENCHOREO_VERSION" \
  --timeout 10m \
  -f - <<EOF
gateway:
  infrastructure:
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-type: external
      service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
      service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
      service.beta.kubernetes.io/aws-load-balancer-eip-allocations: "${DP_EIP_ALLOCATIONS}"
      service.beta.kubernetes.io/aws-load-balancer-subnets: "${DP_SUBNETS}"
      service.beta.kubernetes.io/aws-load-balancer-attributes: load_balancing.cross_zone.enabled=true
  tls:
    hostname: "*.apps.${BASE_DOMAIN}"
    certificateRefs:
      - name: data-plane-tls

clusterAgent:
  planeID: dataplane
  tls:
    generateCerts: true
EOF

# Pin gateway pods to the NLB AZ when using single-subnet mode.
# With IP targets, the NLB can only reach pods in enabled AZs.
if [[ "$DP_SUBNETS" == "$FIRST_SUBNET" ]]; then
  log "Single-AZ DP NLB: pinning gateway-default to ${FIRST_SUBNET_AZ}"
  kubectl patch deployment gateway-default -n openchoreo-data-plane --type=strategic \
    -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"topology.kubernetes.io/zone\":\"${FIRST_SUBNET_AZ}\"}}}}}"
  kubectl rollout status deployment/gateway-default -n openchoreo-data-plane --timeout=120s
fi
if [[ "$CP_SUBNETS" == "$FIRST_SUBNET" ]]; then
  log "Single-AZ CP NLB: pinning gateway-default to ${FIRST_SUBNET_AZ}"
  kubectl patch deployment gateway-default -n openchoreo-control-plane --type=strategic \
    -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"topology.kubernetes.io/zone\":\"${FIRST_SUBNET_AZ}\"}}}}}"
  kubectl rollout status deployment/gateway-default -n openchoreo-control-plane --timeout=120s
fi

# Wait for backstage to be ready
log "Waiting for backstage..."
kubectl rollout status deployment/openchoreo-ui -n openchoreo-control-plane --timeout=300s || true

# ── Step 18: Register DataPlane ──────────────────────────────────────────────
log "Step 18: Registering DataPlane..."

kubectl wait --for=condition=Ready certificate/cluster-agent-dataplane-tls -n openchoreo-data-plane --timeout=300s

DP_CERT=$(kubectl get secret cluster-agent-tls -n openchoreo-data-plane -o jsonpath='{.data.tls\.crt}' | base64 -d)

kubectl apply -f - <<EOF
apiVersion: openchoreo.dev/v1alpha1
kind: DataPlane
metadata:
  name: default
  namespace: default
spec:
  planeID: dataplane
  clusterAgent:
    clientCA:
      value: |
$(echo "$DP_CERT" | sed 's/^/        /')
  gateway:
    publicVirtualHost: apps.${BASE_DOMAIN}
    organizationVirtualHost: apps.${BASE_DOMAIN}
    publicHTTPPort: 80
    publicHTTPSPort: 443
    organizationHTTPPort: 80
    organizationHTTPSPort: 443
  secretStoreRef:
    name: aws-secrets-manager
EOF

# ── Step 19: Install Build Plane ─────────────────────────────────────────────
log "Step 19: Installing Build Plane..."

export ECR_REGISTRY="${ECRUri%%/*}"

helm upgrade --install openchoreo-build-plane \
  oci://ghcr.io/openchoreo/helm-charts/openchoreo-build-plane \
  --namespace openchoreo-build-plane \
  --version "$OPENCHOREO_VERSION" \
  --timeout 10m \
  -f - <<EOF
clusterAgent:
  planeID: buildplane
  tls:
    generateCerts: true

openbao:
  enabled: false
EOF

# ── Step 20: Register BuildPlane ─────────────────────────────────────────────
log "Step 20: Registering BuildPlane..."

kubectl wait --for=condition=Ready certificate/cluster-agent-buildplane-tls -n openchoreo-build-plane --timeout=300s

BP_CERT=$(kubectl get secret cluster-agent-tls -n openchoreo-build-plane -o jsonpath='{.data.tls\.crt}' | base64 -d)

kubectl apply -f - <<EOF
apiVersion: openchoreo.dev/v1alpha1
kind: BuildPlane
metadata:
  name: default
  namespace: default
spec:
  planeID: buildplane
  clusterAgent:
    clientCA:
      value: |
$(echo "$BP_CERT" | sed 's/^/        /')
  secretStoreRef:
    name: aws-secrets-manager
EOF

# ── Step 21: Setup ECR workflow ──────────────────────────────────────────────
log "Step 21: Setting up workflow templates..."

kubectl apply -f "https://raw.githubusercontent.com/openchoreo/openchoreo/${RELEASE_BRANCH}/samples/getting-started/workflow-templates/checkout-source.yaml"
kubectl apply -f "https://raw.githubusercontent.com/openchoreo/openchoreo/${RELEASE_BRANCH}/samples/getting-started/workflow-templates.yaml"

cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: ClusterWorkflowTemplate
metadata:
  name: publish-image
spec:
  templates:
    - name: publish-image
      inputs:
        parameters:
          - name: git-revision
      outputs:
        parameters:
          - name: image
            valueFrom:
              path: /tmp/image.txt
      volumes:
        - name: ecr-auth
          emptyDir: {}
      initContainers:
        - name: ecr-login
          image: amazon/aws-cli:latest
          command: [sh, -c]
          args:
            - |
              set -e
              REPO_NAME="openchoreo-builds/{{workflow.parameters.image-name}}"
              aws ecr describe-repositories --repository-names "\$REPO_NAME" --region ${AWS_REGION} 2>/dev/null || \
                aws ecr create-repository --repository-name "\$REPO_NAME" --region ${AWS_REGION}
              aws ecr get-login-password --region ${AWS_REGION} > /ecr-auth/token
          volumeMounts:
            - name: ecr-auth
              mountPath: /ecr-auth
      container:
        image: ghcr.io/openchoreo/podman-runner:v1.0
        command:
          - sh
          - -c
        args:
          - |-
            set -e

            GIT_REVISION={{inputs.parameters.git-revision}}
            IMAGE_NAME={{workflow.parameters.image-name}}
            IMAGE_TAG={{workflow.parameters.image-tag}}
            SRC_IMAGE="\${IMAGE_NAME}:\${IMAGE_TAG}-\${GIT_REVISION}"

            REGISTRY_ENDPOINT="${ECR_REGISTRY}/openchoreo-builds"

            mkdir -p /etc/containers
            cat <<SEOF > /etc/containers/storage.conf
            [storage]
            driver = "overlay"
            runroot = "/run/containers/storage"
            graphroot = "/var/lib/containers/storage"
            [storage.options.overlay]
            mount_program = "/usr/bin/fuse-overlayfs"
            SEOF

            podman load -i /mnt/vol/app-image.tar

            podman tag \$SRC_IMAGE \$REGISTRY_ENDPOINT/\$SRC_IMAGE

            cat /ecr-auth/token | podman login --username AWS --password-stdin ${ECR_REGISTRY}

            podman push --tls-verify=true \$REGISTRY_ENDPOINT/\$SRC_IMAGE

            echo -n "\$REGISTRY_ENDPOINT/\$SRC_IMAGE" > /tmp/image.txt
        env:
          - name: ECR_REGISTRY
            value: "${ECR_REGISTRY}"
        securityContext:
          privileged: true
        volumeMounts:
          - mountPath: /mnt/vol
            name: workspace
          - mountPath: /ecr-auth
            name: ecr-auth
            readOnly: true
EOF

kubectl create namespace openchoreo-ci-default --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: workflow-sa
  namespace: openchoreo-ci-default
  annotations:
    eks.amazonaws.com/role-arn: "${BuildRoleArn}"
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: workflow-sa
  namespace: openchoreo-build-plane
  annotations:
    eks.amazonaws.com/role-arn: "${BuildRoleArn}"
EOF

log "Creating registry-push-secret in Secrets Manager..."
ECR_TOKEN=$(aws ecr get-login-password --region "$AWS_REGION")
aws secretsmanager create-secret \
  --name "registry-push-secret" \
  --secret-string "{\"auths\":{\"${ECR_REGISTRY}\":{\"username\":\"AWS\",\"password\":\"${ECR_TOKEN}\"}}}" \
  --region "$AWS_REGION" 2>/dev/null || \
aws secretsmanager update-secret \
  --secret-id "registry-push-secret" \
  --secret-string "{\"auths\":{\"${ECR_REGISTRY}\":{\"username\":\"AWS\",\"password\":\"${ECR_TOKEN}\"}}}" \
  --region "$AWS_REGION"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws iam put-role-policy \
  --role-name "${STACK_NAME}-eso" \
  --policy-name registry-push-secret-access \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"secretsmanager:GetSecretValue\",\"secretsmanager:DescribeSecret\"],\"Resource\":\"arn:aws:secretsmanager:${AWS_REGION}:${ACCOUNT_ID}:secret:registry-push-secret*\"}]}"

# ── Step 22: Install Observability Plane ─────────────────────────────────────
log "Step 22: Installing Observability Plane..."

helm repo add opensearch-operator https://opensearch-project.github.io/opensearch-k8s-operator/ 2>/dev/null || true
helm repo update opensearch-operator

helm upgrade --install opensearch-operator opensearch-operator/opensearch-operator \
  --namespace openchoreo-observability-plane \
  --version 2.8.0 \
  --wait --timeout 180s

kubectl create secret generic observer-opensearch-credentials \
  --namespace openchoreo-observability-plane \
  --from-literal=username=admin \
  --from-literal=password=ThisIsTheOpenSearchPassword1 \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic opensearch-admin-credentials \
  --namespace openchoreo-observability-plane \
  --from-literal=username=admin \
  --from-literal=password=ThisIsTheOpenSearchPassword1 \
  --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install openchoreo-observability-plane \
  oci://ghcr.io/openchoreo/helm-charts/openchoreo-observability-plane \
  --namespace openchoreo-observability-plane \
  --version "$OPENCHOREO_VERSION" \
  --timeout 15m \
  -f - <<EOF
security:
  oidc:
    jwksUrl: "${COGNITO_JWKS_URL}"
    tokenUrl: "${COGNITO_DOMAIN_URL}/oauth2/token"

clusterAgent:
  planeID: observabilityplane
  tls:
    generateCerts: true

observer:
  openSearchSecretName: observer-opensearch-credentials
  controlPlaneApiUrl: "http://openchoreo-api.openchoreo-control-plane.svc.cluster.local:8080"
  extraEnvs:
    - name: OBSERVER_BASE_URL
      value: "http://localhost:11080"
    - name: OPENSEARCH_ADDRESS
      value: "https://opensearch:9200"
    - name: PROMETHEUS_ADDRESS
      value: "http://openchoreo-observability-prometheus:9091"
    - name: PROMETHEUS_TIMEOUT
      value: "30s"
    - name: AUTHZ_TIMEOUT
      value: "30s"
    - name: AUTH_SERVER_BASE_URL
      value: "${COGNITO_DOMAIN_URL}"
  security:
    userTypes:
      - type: "user"
        display_name: "User"
        priority: 1
        auth_mechanisms:
          - type: "jwt"
            entitlement:
              claim: "cognito:groups"
              display_name: "User Group"
      - type: "service_account"
        display_name: "Service Account"
        priority: 2
        auth_mechanisms:
          - type: "jwt"
            entitlement:
              claim: "sub"
              display_name: "Client ID"

gateway:
  enabled: false

openSearchCluster:
  enabled: false

fluent-bit:
  enabled: false

opentelemetry-collector:
  enabled: false

openSearch:
  enabled: false
EOF

log "Installing observability-logs-opensearch module (skipping hooks)..."
# Helm always waits for hook jobs, and the opensearch-setup-logs hook needs
# OpenSearch running. Install without hooks first, wait for OpenSearch, then
# run an upgrade to trigger the post-upgrade hook with OpenSearch already up.
helm upgrade --install observability-logs-opensearch \
  oci://ghcr.io/openchoreo/charts/observability-logs-opensearch \
  --namespace openchoreo-observability-plane \
  --set openSearchSetup.openSearchSecretName="opensearch-admin-credentials" \
  --no-hooks \
  --timeout 15m \
  --wait

# Wait for OpenSearch pods to be ready before triggering setup hooks
log "Waiting for OpenSearch pods..."
for i in $(seq 1 60); do
  if kubectl get pods -n openchoreo-observability-plane -l opster.io/opensearch-cluster \
    -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then
    log "OpenSearch pods are ready"
    break
  fi
  if (( i % 10 == 0 )); then log "Still waiting for OpenSearch pods... (${i}/60)"; fi
  sleep 10
done

# Trigger setup hooks now that OpenSearch is ready
log "Running helm upgrade to trigger opensearch setup hooks..."
helm upgrade observability-logs-opensearch \
  oci://ghcr.io/openchoreo/charts/observability-logs-opensearch \
  --namespace openchoreo-observability-plane \
  --reuse-values \
  --timeout 10m \
  --wait

log "Enabling fluent-bit on observability-logs-opensearch..."
helm upgrade observability-logs-opensearch \
  oci://ghcr.io/openchoreo/charts/observability-logs-opensearch \
  --namespace openchoreo-observability-plane \
  --reuse-values \
  --set fluent-bit.enabled=true \
  --timeout 10m \
  --wait

log "Installing observability-metrics-prometheus module..."
helm upgrade --install observability-metrics-prometheus \
  oci://ghcr.io/openchoreo/charts/observability-metrics-prometheus \
  --namespace openchoreo-observability-plane \
  --timeout 10m \
  --wait

log "Installing observability-tracing-opensearch module..."
helm upgrade --install observability-tracing-opensearch \
  oci://ghcr.io/openchoreo/charts/observability-tracing-opensearch \
  --namespace openchoreo-observability-plane \
  --set openSearch.enabled=false \
  --set openSearchSetup.openSearchSecretName="opensearch-admin-credentials" \
  --timeout 10m \
  --wait

# ── Step 23: Register ObservabilityPlane ─────────────────────────────────────
log "Step 23: Registering ObservabilityPlane..."

kubectl wait --for=condition=Ready certificate/cluster-agent-observabilityplane-tls \
  -n openchoreo-observability-plane --timeout=300s

OP_CERT=$(kubectl get secret cluster-agent-tls -n openchoreo-observability-plane -o jsonpath='{.data.tls\.crt}' | base64 -d)

kubectl apply -f - <<EOF
apiVersion: openchoreo.dev/v1alpha1
kind: ObservabilityPlane
metadata:
  name: default
  namespace: default
spec:
  planeID: observabilityplane
  clusterAgent:
    clientCA:
      value: |
$(echo "$OP_CERT" | sed 's/^/        /')
  observerURL: http://observer.openchoreo-observability-plane.svc.cluster.local:8080
EOF

kubectl patch dataplane default -n default --type merge -p '{"spec":{"observabilityPlaneRef":{"kind":"ObservabilityPlane","name":"default"}}}' || true
kubectl patch buildplane default -n default --type merge -p '{"spec":{"observabilityPlaneRef":{"kind":"ObservabilityPlane","name":"default"}}}' || true

# ── Step 24: Apply default resources ─────────────────────────────────────────
log "Step 24: Applying default resources..."

kubectl label namespace default openchoreo.dev/controlplane-namespace=true --overwrite
kubectl apply -f "https://raw.githubusercontent.com/openchoreo/openchoreo/${RELEASE_BRANCH}/samples/getting-started/all.yaml"

# ── Done ─────────────────────────────────────────────────────────────────────
log "Bootstrap complete."
log "Console: https://console.${BASE_DOMAIN} (self-signed cert)"
log "API:     https://api.${BASE_DOMAIN}"

# Clear the failure trap before signaling success
trap - EXIT ERR
signal_success
