# Advanced Setup

## Table of Contents

- [Certificate Management](#certificate-management)
- [Private Git Repositories](#private-git-repositories)
- [Customizing Build Workflows](#customizing-build-workflows)
- [Identity Provider Setup](#identity-provider-setup)

## Certificate Management

OpenChoreo uses mTLS between the Cluster Gateway (control plane) and Cluster Agents (remote planes). By default cert-manager handles the full lifecycle. You can replace it with any certificate source.

### What gets certificates

```
Your CA
  ├── Gateway Server Cert (control plane)
  │     Secret: cluster-gateway-tls
  │     Used by: cluster-gateway deployment
  │     DNS SANs: cluster-gateway.<cp-namespace>.svc,
  │               cluster-gateway.<cp-namespace>.svc.cluster.local
  │
  └── Agent Client Cert (one per plane)
        Secret: cluster-agent-tls
        Used by: cluster-agent deployment
        CN: must match planeID
        EKU: clientAuth
```

The CA cert is distributed via ConfigMap `cluster-gateway-ca` to both control plane and remote planes.

### Using cert-manager (default)

cert-manager is installed on all clusters. The Helm charts create Issuer and Certificate resources automatically. Nothing to configure beyond the standard install.

### Using an external CA

For air-gapped environments, corporate PKI mandates, or when cert-manager isn't desired.

#### Generate certificates

```bash
# CA (10 year validity)
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
  -out ca.crt -subj "/CN=openchoreo-cluster-gateway-ca/O=OpenChoreo"

# Gateway server cert
openssl genrsa -out gateway-server.key 2048

cat > gateway-server-csr.conf <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = cluster-gateway.openchoreo-control-plane.svc
DNS.2 = cluster-gateway.openchoreo-control-plane.svc.cluster.local
EOF

openssl req -new -key gateway-server.key -out gateway-server.csr \
  -subj "/CN=cluster-gateway/O=OpenChoreo" -config gateway-server-csr.conf
openssl x509 -req -in gateway-server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out gateway-server.crt -days 365 -sha256 -extensions v3_req -extfile gateway-server-csr.conf

# Agent client cert (repeat per plane, CN must match planeID)
PLANE_ID="default"
openssl genrsa -out agent.key 2048
openssl req -new -key agent.key -out agent.csr -subj "/CN=${PLANE_ID}/O=OpenChoreo"

cat > agent-ext.conf <<EOF
basicConstraints = CA:FALSE
keyUsage = digitalSignature
extendedKeyUsage = clientAuth
EOF

openssl x509 -req -in agent.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out agent.crt -days 365 -sha256 -extfile agent-ext.conf
```

If connecting to the gateway via an external DNS name or IP, add those to the server cert's `alt_names` section.

#### Create secrets before Helm install

```bash
# Control plane
kubectl create secret tls cluster-gateway-tls --cert=gateway-server.crt --key=gateway-server.key -n openchoreo-control-plane
kubectl create configmap cluster-gateway-ca --from-file=ca.crt=ca.crt -n openchoreo-control-plane

# Each remote plane (data, build, observability)
kubectl create secret tls cluster-agent-tls --cert=agent.crt --key=agent.key -n openchoreo-data-plane
kubectl create configmap cluster-gateway-ca --from-file=ca.crt=ca.crt -n openchoreo-data-plane
```

#### Handle cert-manager CRD dependency

The Helm charts include cert-manager Certificate/Issuer templates. Without cert-manager CRDs in the cluster, Helm will fail. Install only the CRDs (no controller, no pods):

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.19.3/cert-manager.crds.yaml
```

The Certificate and Issuer resources will render but sit idle since no controller processes them. Your pre-created secrets are used directly.

#### Helm values

No special values needed. Deployments mount from `secretName` and `serverCAConfigMap` regardless of how the secrets were created:

```yaml
# Control Plane
clusterGateway:
  tls:
    enabled: true
    secretName: cluster-gateway-tls

# Remote Planes
clusterAgent:
  tls:
    enabled: true
    clientSecretName: cluster-agent-tls
    serverCAConfigMap: cluster-gateway-ca
```

#### Certificate renewal

Certificates are loaded at startup, not hot-reloaded. After updating secrets:

```bash
kubectl create secret tls cluster-gateway-tls --cert=new.crt --key=new.key \
  -n openchoreo-control-plane --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment cluster-gateway -n openchoreo-control-plane
```

Same pattern for agents.

### Using Let's Encrypt (production domains)

For production with real domains, create a cert-manager ClusterIssuer that uses ACME:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: openchoreo-issuer
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      # Cloudflare DNS-01
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
      # Or Route53 DNS-01
      # - dns01:
      #     route53:
      #       hostedZoneID: Z1234567890
      #       region: us-east-1
```

The control plane and data plane TLS certificates for ingress (console, API, app endpoints) can reference this issuer. The mTLS certificates for gateway-agent communication are separate and typically use the self-signed CA chain.

## Private Git Repositories

Build workflows need to clone source code. For private repos, store Git credentials in your secret backend and reference them in the workflow.

### Store credentials

```bash
# For GitHub personal access token
kubectl exec -n openbao openbao-0 -- sh -c '
  export BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=root
  bao kv put secret/git-token value="ghp_your_token_here"
'
```

For AWS Secrets Manager:
```bash
aws secretsmanager create-secret --name openchoreo/git-token \
  --secret-string '{"value":"ghp_your_token_here"}'
```

### Reference in Component workflow

The Component's `spec.workflow.systemParameters.repository.secretRef` tells the workflow where to find credentials:

```yaml
spec:
  workflow:
    name: docker
    parameters:
      scope:
        projectName: my-project
        componentName: my-app
      repository:
        url: "https://github.com/my-org/private-repo"
        secretRef: git-token
        revision:
          branch: main
        appPath: "."
```

The `secretRef` name maps to a SecretReference resource that pulls the token from the secret backend. The checkout step in the ClusterWorkflowTemplate uses this token for authentication.

### Create the SecretReference

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: SecretReference
metadata:
  name: git-token
  namespace: default
spec:
  data:
    - secretKey: value
      remoteRef:
        key: git-token
        property: value
  refreshInterval: 1h
```

## Customizing Build Workflows

Build workflows are backed by ClusterWorkflowTemplates on the Build Plane cluster. The two key templates to customize are `checkout-source` and `publish-image`.

### Viewing current templates

```bash
kubectl get clusterworkflowtemplates
kubectl get clusterworkflowtemplate publish-image -o yaml
kubectl get clusterworkflowtemplate checkout-source -o yaml
```

### Custom container registry (publish-image)

Replace the `publish-image` ClusterWorkflowTemplate to push to your registry. The template receives the built image as `/mnt/vol/app-image.tar` and must output the final image reference to `/tmp/image.txt`.

#### ECR example

```yaml
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
      initContainers:
        - name: ecr-login
          image: public.ecr.aws/aws-cli/aws-cli:latest
          command: [sh, -c]
          args:
            - |
              ECR_REGISTRY="{{workflow.parameters.registry-endpoint}}"
              REPO_NAME="openchoreo-builds/{{workflow.parameters.image-name}}"

              # Create repo if it doesn't exist
              aws ecr describe-repositories --repository-names "$REPO_NAME" 2>/dev/null || \
                aws ecr create-repository --repository-name "$REPO_NAME"

              # Get auth token
              aws ecr get-login-password > /mnt/vol/ecr-token
              echo -n "$ECR_REGISTRY" > /mnt/vol/ecr-registry
          volumeMounts:
            - mountPath: /mnt/vol
              name: workspace
      container:
        image: ghcr.io/openchoreo/podman-runner:v1.0
        command: [sh, -c]
        args:
          - |
            set -e
            ECR_REGISTRY=$(cat /mnt/vol/ecr-registry)
            ECR_TOKEN=$(cat /mnt/vol/ecr-token)
            IMAGE_NAME="{{workflow.parameters.image-name}}"
            IMAGE_TAG="{{workflow.parameters.image-tag}}"
            GIT_REV="{{inputs.parameters.git-revision}}"
            SRC="${IMAGE_NAME}:${IMAGE_TAG}-${GIT_REV}"
            DEST="${ECR_REGISTRY}/openchoreo-builds/${SRC}"

            podman load -i /mnt/vol/app-image.tar
            podman tag "$SRC" "$DEST"
            podman login -u AWS -p "$ECR_TOKEN" "$ECR_REGISTRY"
            podman push --tls-verify=true "$DEST"
            echo -n "$DEST" > /tmp/image.txt
        securityContext:
          privileged: true
        volumeMounts:
          - mountPath: /mnt/vol
            name: workspace
```

#### GCR / Artifact Registry example

Same pattern but use `gcloud auth configure-docker` or a service account key mounted as a secret.

#### Generic authenticated registry

For registries that accept docker config auth:

1. Store credentials as a registry push secret (see `integrations.md` > Container Registry)
2. Mount the secret in the publish-image template
3. Use `podman push --authfile /path/to/.dockerconfigjson`

### Build plane service account

The build workflow pods run as a specific service account. For cloud registries with IAM-based auth, annotate the service account:

```bash
# AWS (IRSA)
kubectl annotate serviceaccount workflow-sa \
  -n openchoreo-build-plane \
  eks.amazonaws.com/role-arn="arn:aws:iam::ACCOUNT:role/BuildRole"

# Same for the CI namespace
kubectl annotate serviceaccount workflow-sa \
  -n openchoreo-ci-default \
  eks.amazonaws.com/role-arn="arn:aws:iam::ACCOUNT:role/BuildRole"
```

For GKE Workload Identity or Azure Workload Identity, use the equivalent annotation pattern.

### Custom build steps

You can add steps to the workflow (linting, scanning, testing) by modifying the ClusterWorkflowTemplate. The key constraint: the last step must still be `generate-workload-cr` with output parameter `workload-cr` for the controller to pick up the built workload.

## Identity Provider Setup

OpenChoreo ships with Thunder as its default IdP. For production, swap to your organization's IdP.

### What needs configuration

Five OAuth2 clients are needed:

| Client | Flow | Purpose |
|--------|------|---------|
| Backstage Console | Authorization code + refresh | Web UI login |
| occ CLI | Authorization code (public, PKCE) | CLI authentication |
| Backend Service Account | Client credentials | Internal API calls |
| Observer | Client credentials | Observability queries |
| RCA Agent | Client credentials | Root cause analysis |

### What to configure

Swapping the IdP touches several components. Here's the full picture:

**Control Plane Helm values:**
- OIDC endpoints (issuer, JWKS, auth URL, token URL)
- CLI client registration (`externalClients`)
- Groups claim mapping (`security.subjects`)
- Authorization bindings (map IdP groups/client IDs to OpenChoreo roles)
- Backstage OAuth client ID (`backstage.auth.clientId`)

**Backstage backend auth:**
- A `backstage-ci-config` ConfigMap with a backend service account's client credentials for internal API calls

**Backstage secrets:**
- Client secret for the Backstage console OAuth client (synced via ExternalSecret)

**Observability Plane Helm values:**
- JWKS URL and token URL for JWT validation
- Observer OAuth client credentials (`observer.oauthClientId`, `observer.oauthClientSecret`)
- RCA agent OAuth client credentials (`rca.oauth.clientId`, `rca.oauth.clientSecret`)
- Security user type config (which JWT claim maps to groups)

### Full control plane configuration

This shows every IdP-related value in the control plane Helm install. Replace the placeholder values with your IdP's actual values:

```yaml
security:
  oidc:
    issuer: "https://your-idp.example.com/..."
    wellKnownEndpoint: "https://your-idp.example.com/.well-known/openid-configuration"
    jwksUrl: "https://your-idp.example.com/.well-known/jwks.json"
    authorizationUrl: "https://your-idp.example.com/oauth2/authorize"
    tokenUrl: "https://your-idp.example.com/oauth2/token"
    externalClients:
      - name: cli
        client_id: "<CLI_CLIENT_ID>"       # public client, no secret
        scopes:
          - "openid"
          - "profile"
          - "email"
  jwt:
    audience: "your-audience"              # optional

openchoreoApi:
  config:
    security:
      subjects:
        user:
          mechanisms:
            jwt:
              entitlement:
                claim: "groups"            # or "cognito:groups" for Cognito
      authorization:
        bootstrap:
          mappings:
            - name: super-admin-binding
              roleRef: {name: super-admin}
              entitlement: {claim: "groups", value: "admin"}
              effect: allow
            - name: backstage-catalog-reader-binding
              roleRef: {name: backstage-catalog-reader}
              entitlement: {claim: sub, value: "<BACKEND_CLIENT_ID>"}
              effect: allow
            - name: observer-binding
              roleRef: {name: observer}
              entitlement: {claim: sub, value: "<OBSERVER_CLIENT_ID>"}
              effect: allow
            - name: rca-agent-binding
              roleRef: {name: rca-agent}
              entitlement: {claim: sub, value: "<RCA_CLIENT_ID>"}
              effect: allow

backstage:
  secretName: openchoreo-backstage-secrets  # ExternalSecret syncs client_secret here
  auth:
    clientId: "<BACKSTAGE_CLIENT_ID>"
```

The `entitlement.claim` for groups depends on your IdP. Cognito uses `cognito:groups`, Keycloak uses `groups` by default, Auth0 might use a custom namespace like `https://your-app/groups`.

**You must override all default mappings.** The chart ships with default bindings that reference Thunder's client names (`openchoreo-backstage-client`, `openchoreo-rca-agent`, `openchoreo-observer`, `platformEngineer`). These won't match your IdP's client IDs or group names, so every mapping must be redefined with your actual values. The roles themselves (`super-admin`, `backstage-catalog-reader`, `observer`, `rca-agent`) define permissions and stay the same. It's the mappings (bindings) that tie those roles to your IdP's identities.

### Backstage backend service account

Backstage needs a service account (client_credentials flow) for internal API calls. Create a ConfigMap with the backend client credentials:

```bash
kubectl create configmap backstage-ci-config \
  -n openchoreo-control-plane \
  --from-literal=app-config.ci.yaml="$(cat <<EOF
openchoreo:
  auth:
    clientId: "<BACKEND_CLIENT_ID>"
    clientSecret: "<BACKEND_CLIENT_SECRET>"
    tokenUrl: "https://your-idp.example.com/oauth2/token"
    scopes:
      - "openchoreo-api/internal"
EOF
)" --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart deployment/backstage -n openchoreo-control-plane
```

The scope `openchoreo-api/internal` (or your IdP's equivalent) must be configured as a resource server scope in your IdP.

### Backstage client secret

Store the Backstage console client secret in your secret backend and sync via ExternalSecret. The secret must contain a `client-secret` key:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: openchoreo-backstage-secrets
  namespace: openchoreo-control-plane
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: your-secret-store
    kind: ClusterSecretStore
  target:
    name: openchoreo-backstage-secrets
  data:
    - secretKey: client_secret
      remoteRef:
        key: your-idp/backstage-client
        property: client_secret
```

### Observability plane configuration

The observability plane needs its own IdP config for JWT validation, plus client credentials for the Observer and RCA agent:

```yaml
security:
  oidc:
    jwksUrl: "https://your-idp.example.com/.well-known/jwks.json"
    tokenUrl: "https://your-idp.example.com/oauth2/token"

observer:
  oauthClientId: "<OBSERVER_CLIENT_ID>"
  oauthClientSecret: "<OBSERVER_CLIENT_SECRET>"
  controlPlaneApiUrl: "http://openchoreo-api.openchoreo-control-plane.svc.cluster.local:8080"
  security:
    userTypes:
      - type: "user"
        display_name: "User"
        priority: 1
        auth_mechanisms:
          - type: "jwt"
            entitlement:
              claim: "groups"              # match your IdP's groups claim
              display_name: "User Group"
      - type: "service_account"
        display_name: "Service Account"
        priority: 2
        auth_mechanisms:
          - type: "jwt"
            entitlement:
              claim: "sub"
              display_name: "Client ID"

rca:
  enabled: true
  controlPlaneUrl: "http://openchoreo-api.openchoreo-control-plane.svc.cluster.local:8080"
  observerMcpUrl: "http://observer.openchoreo-observability-plane.svc.cluster.local:8080"
  oauth:
    clientId: "<RCA_CLIENT_ID>"
    clientSecret: "<RCA_CLIENT_SECRET>"
```

### AWS Cognito specifics

Cognito requires extra setup compared to other IdPs:

- **Pre-token Lambda**: Cognito doesn't include groups in JWTs by default. You need a pre-token-generation Lambda that injects `cognito:groups` into the ID token claims.
- **Resource server**: Create a resource server (e.g., `openchoreo-api`) with scope `internal` to enable `client_credentials` flow for service accounts.
- **Custom domain**: Required for the OAuth2 endpoints. Format: `your-stack-auth.auth.us-east-1.amazoncognito.com`
- **Groups claim**: Use `cognito:groups` (not `groups`) in all entitlement configs.

```bash
COGNITO_DOMAIN="your-stack-auth.auth.us-east-1.amazoncognito.com"
POOL_ID="us-east-1_XXXXXXXXX"
ISSUER="https://cognito-idp.us-east-1.amazonaws.com/${POOL_ID}"

# Control plane
helm upgrade openchoreo-control-plane ... \
  --set security.oidc.issuer="${ISSUER}" \
  --set security.oidc.jwksUrl="${ISSUER}/.well-known/jwks.json" \
  --set security.oidc.authorizationUrl="https://${COGNITO_DOMAIN}/oauth2/authorize" \
  --set security.oidc.tokenUrl="https://${COGNITO_DOMAIN}/oauth2/token"
```

Store all client secrets in AWS Secrets Manager and sync via ESO with the `aws` provider.

### Keycloak specifics

Keycloak is simpler because it includes groups in JWTs by default via protocol mappers.

```bash
KEYCLOAK_URL="https://keycloak.example.com"
REALM="openchoreo"
BASE="${KEYCLOAK_URL}/realms/${REALM}"

helm upgrade openchoreo-control-plane ... \
  --set security.oidc.issuer="${BASE}" \
  --set security.oidc.jwksUrl="${BASE}/protocol/openid-connect/certs" \
  --set security.oidc.authorizationUrl="${BASE}/protocol/openid-connect/auth" \
  --set security.oidc.tokenUrl="${BASE}/protocol/openid-connect/token"
```

The groups claim is `groups` by default. Create a `client_credentials` service account for each backend client in the realm settings.

### Auth0, Okta, Azure AD

Same pattern. The IdP must:

1. Include a `groups` claim in JWTs (configure a custom rule/action/mapper if not default)
2. Support `client_credentials` flow for the three service accounts
3. Support authorization code + PKCE for the CLI client (public client, no secret)
4. Have a callback URL registered for Backstage: `https://console.<domain>/api/auth/openchoreo-auth/handler/frame`

### Troubleshooting IdP issues

```bash
# Check API server logs for auth errors
kubectl logs deployment/openchoreo-api -n openchoreo-control-plane --tail=50

# Check JWKS accessibility from inside the cluster
kubectl run curl-test --rm -it --image=curlimages/curl -- \
  curl -s "https://your-idp.example.com/.well-known/jwks.json"

# Check Backstage auth errors
kubectl logs deployment/backstage -n openchoreo-control-plane --tail=50

# Check observer auth
kubectl logs deployment/observer -n openchoreo-observability-plane --tail=50
```

Common issues:
- Issuer in JWT doesn't match `security.oidc.issuer` exactly (trailing slash matters)
- JWKS URL not reachable from inside the cluster (DNS or firewall)
- Groups claim missing from JWT (need IdP-specific mapper/Lambda)
- Audience mismatch (check `security.jwt.audience`)
- Backend service account can't get tokens (wrong scope or client credentials)
- Backstage callback URL not registered in IdP (login redirects fail)
- Observer/RCA can't authenticate (client ID or secret wrong in Helm values)
