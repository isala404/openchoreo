# Integrations

## Table of Contents

- [Secret Management](#secret-management)
- [Container Registry](#container-registry)
- [Identity Provider](#identity-provider)
- [Authorization](#authorization)
- [Auto-Build Webhooks](#auto-build-webhooks)
- [API Management](#api-management)

## Secret Management

OpenChoreo uses External Secrets Operator (ESO) to sync secrets from external stores into Kubernetes.

### Install ESO (prerequisite on all clusters needing secrets)

```bash
helm upgrade --install external-secrets \
  oci://ghcr.io/external-secrets/charts/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --version 1.3.2 \
  --set installCRDs=true

kubectl wait --for=condition=available deployment/external-secrets \
  -n external-secrets --timeout=180s
```

### Create a ClusterSecretStore

This depends on your secret backend. Common providers:

- HashiCorp Vault / OpenBao
- AWS Secrets Manager
- Azure Key Vault
- GCP Secret Manager

See [ESO provider docs](https://external-secrets.io/latest/provider/) for provider-specific auth setup.

### Development setup with OpenBao

```bash
helm upgrade --install openbao oci://ghcr.io/openbao/charts/openbao \
  --namespace openbao \
  --create-namespace \
  --version 0.4.0 \
  --set server.image.tag=2.4.4 \
  --set injector.enabled=false \
  --set server.dev.enabled=true \
  --set server.dev.devRootToken=root \
  --wait --timeout 300s
```

Write secrets:
```bash
kubectl exec -n openbao openbao-0 -- sh -c '
  export BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=root
  bao kv put secret/my-secret key=value
'
```

### Reference in DataPlane

```yaml
spec:
  secretStoreRef:
    name: <your-cluster-secret-store>
```

### Platform secrets to provision

These secrets are used by OpenChoreo components:

- `backstage-backend-secret` - Backstage session/auth
- `thunder-client-secret` - Thunder IdP client
- `cluster-gateway-ca` - Control Plane CA (auto-generated)
- `cluster-agent-tls` - Agent mTLS cert (auto-generated)
- `registry-push-secret` - Container registry push credentials (if using authenticated registry)

## Container Registry

Registry configuration lives in the `publish-image` ClusterWorkflowTemplate, not in Helm values.

### Configure a custom registry

Replace the `publish-image` ClusterWorkflowTemplate. Key changes:

1. Set `REGISTRY_ENDPOINT` to your registry
2. Configure TLS verification
3. Mount registry push secret if authentication is needed

### Create push secret

```bash
# Encode credentials
echo -n 'username:password' | base64

# Store in secret backend
kubectl exec -n openbao openbao-0 -- sh -c '
  export BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=root
  bao kv put secret/registry-push-secret \
    value="{\"auths\":{\"<REGISTRY-HOST>\":{\"auth\":\"<BASE64-TOKEN>\"}}}"
'
```

### Pull secrets for private images

To pull from private registries at runtime:

1. Store credentials in the secret backend
2. Add an ExternalSecret to the ComponentType that syncs credentials
3. Add `imagePullSecrets` to the Deployment template in the ComponentType
4. Reference the SecretReference in the DataPlane's `imagePullSecretRefs`

## Identity Provider

### Default: Thunder

OpenChoreo ships with Thunder, a lightweight OAuth2/OIDC provider with a developer portal at `/develop`. Good enough for development, not intended for production.

### Configure external IdP

Control Plane:

```bash
helm upgrade openchoreo-control-plane \
  oci://ghcr.io/openchoreo/helm-charts/openchoreo-control-plane \
  --namespace openchoreo-control-plane \
  --reuse-values \
  --set security.oidc.issuer="https://your-idp.example.com" \
  --set security.oidc.wellKnownEndpoint="https://your-idp.example.com/.well-known/openid-configuration" \
  --set security.oidc.jwksUrl="https://your-idp.example.com/.well-known/jwks.json" \
  --set security.oidc.authorizationUrl="https://your-idp.example.com/oauth2/authorize" \
  --set security.oidc.tokenUrl="https://your-idp.example.com/oauth2/token" \
  --set security.jwt.audience="your-audience"
```

Observability Plane (if installed):

```bash
helm upgrade openchoreo-observability-plane \
  oci://ghcr.io/openchoreo/helm-charts/openchoreo-observability-plane \
  --namespace openchoreo-observability-plane \
  --reuse-values \
  --set security.oidc.issuer="https://your-idp.example.com" \
  --set security.oidc.jwksUrl="https://your-idp.example.com/.well-known/jwks.json"
```

### Required OAuth2 clients

Create these in your IdP:
- **Backstage** - web app, needs redirect URIs to Backstage URL
- **RCA Agent** - service account for root cause analysis
- **occ CLI** - public client for PKCE auth flow

### Troubleshooting IdP

- Verify issuer matches JWT `iss` claim
- Confirm JWKS URL is accessible and returns valid keys
- Check audience matches JWT `aud` claim
- Check network connectivity between OpenChoreo pods and IdP

## Authorization

### Enable/disable

```yaml
# In Helm values
security:
  authz:
    enabled: true  # default
```

### Default roles

| Role | Scope | Permissions |
|------|-------|-------------|
| `super-admin` | All | Everything |
| `backstage-catalog-reader` | Catalog | Read-only |
| `rca-agent` | Observability | Read components + observability |

### Default bindings

- `super-admin-binding`: `groups:platformEngineer` maps to `super-admin`
- `backstage-catalog-reader-binding`: Backstage service account
- `rca-agent-binding`: RCA agent service account

### Custom roles and bindings

```yaml
# In Helm values
openchoreoApi:
  config:
    security:
      authorization:
        bootstrap:
          roles:
            - name: developer
              namespace: acme
              description: "Developer access"
              actions:
                - "component:*"
                - "project:view"
                - "workflow:view"
          mappings:
            - name: dev-team-binding
              roleRef:
                name: developer
                namespace: acme
              entitlement:
                claim: groups
                value: dev-team
              effect: allow
              hierarchy:
                namespace: acme
```

### Subject types

Configure how JWT claims map to authorization subjects:

```yaml
openchoreoApi:
  config:
    security:
      subjects:
        - claim: groups
          type: user_group
        - claim: sub
          type: client_id
```

## Auto-Build Webhooks

### Setup

1. Create webhook secret:
   ```bash
   WEBHOOK_SECRET=$(openssl rand -hex 32)
   kubectl create secret generic git-webhook-secrets \
     -n openchoreo-control-plane \
     --from-literal=github-secret="$WEBHOOK_SECRET"
   ```

2. Enable `autoBuild: true` on Component spec

3. Configure webhook in Git provider:
   - Payload URL: `https://<openchoreo-api-domain>/api/v1alpha1/autobuild`
   - Content type: `application/json`
   - Secret: the webhook secret value
   - Events: push events only

### Verify

```bash
# Push code, then check:
kubectl get workflowrun -A
```

## API Management

### WSO2 API Platform (default)

Enable during Data Plane install:

```bash
helm upgrade openchoreo-data-plane \
  oci://ghcr.io/openchoreo/helm-charts/openchoreo-data-plane \
  --namespace openchoreo-data-plane \
  --reuse-values \
  --set api-platform.enabled=true
```

Install CRDs first:

```bash
kubectl apply --server-side \
  -f https://raw.githubusercontent.com/wso2/api-platform/gateway-v0.3.0/kubernetes/helm/operator-helm-chart/crds/gateway.api-platform.wso2.com_restapis.yaml \
  -f https://raw.githubusercontent.com/wso2/api-platform/gateway-v0.3.0/kubernetes/helm/operator-helm-chart/crds/gateway.api-platform.wso2.com_gateways.yaml
```

Developers attach the `api-configuration` trait to enable API management on their components.

### Custom API gateway traits

For other vendors (Kong, Apigee, etc.), create Traits that generate vendor-specific resources and patch Ingress/Service resources accordingly.
