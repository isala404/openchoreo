# Community Modules

Community modules are pluggable extensions for OpenChoreo. They let you swap out subsystems (gateway controllers, observability backends) without modifying the control plane.

Repository: https://github.com/openchoreo/community-modules

## How modules work

Each module provides:
- A Helm chart (published to `ghcr.io/openchoreo/helm-charts/`)
- A Trait definition (for gateway modules) or adapter code (for observability modules)
- A README with installation steps

The control plane stays agnostic. It renders standard Kubernetes resources (Gateway API HTTPRoutes, etc.) and any compliant controller will handle them.

## Available modules

### Gateway modules

Swap the default kgateway for a different Gateway API implementation. Pick one:

| Module | Controller | Key CRDs |
|--------|-----------|----------|
| `gateway-envoy-gateway` | Envoy Gateway | BackendTrafficPolicy, SecurityPolicy |
| `gateway-kong` | Kong Ingress Controller | KongPlugin, KongClusterPlugin |
| `gateway-traefik` | Traefik Proxy v3 | Middleware (via ExtensionRef) |

All three support rate limiting, authentication, and request transformation through their respective trait definitions.

### Observability modules

Mix and match per signal type:

| Module | Signal | Collector | Backend |
|--------|--------|-----------|---------|
| `observability-logs-openobserve` | Logs | Fluent Bit | OpenObserve |
| `observability-logs-opensearch` | Logs | Fluent Bit | OpenSearch |
| `observability-metrics-prometheus` | Metrics | Prometheus | Prometheus |
| `observability-tracing-openobserve` | Traces | OTel Collector | OpenObserve |
| `observability-tracing-opensearch` | Traces | OTel Collector | OpenSearch |

## Installing a module

The pattern is the same across all modules:

### 1. Install the controller or backend

```bash
helm upgrade --install <module-name> \
  oci://ghcr.io/openchoreo/helm-charts/<module-name> \
  --namespace <target-namespace> \
  --create-namespace \
  --version <version>
```

Some modules need secrets created first (check the module README):

```bash
kubectl create secret generic <secret-name> \
  --namespace <namespace> \
  --from-literal=key=value
```

### 2. Grant RBAC to the data plane agent

The agent needs permissions for the module's CRDs:

```bash
kubectl patch clusterrole cluster-agent-dataplane-openchoreo-data-plane \
  --type=json \
  -p '[{"op":"add","path":"/rules/-","value":{
    "apiGroups":["<module-api-group>"],
    "resources":["<module-resources>"],
    "verbs":["*"]
  }}]'
```

### 3. Apply the trait definition

```bash
kubectl apply -f <module-trait>.yaml
```

This makes the module's features available to components through the trait system.

### 4. Update the data plane configuration

For gateway modules:

```bash
helm upgrade openchoreo-data-plane \
  oci://ghcr.io/openchoreo/helm-charts/openchoreo-data-plane \
  --namespace openchoreo-data-plane \
  --reuse-values \
  --set gateway.gatewayClassName=<new-class>
```

## Swapping a gateway

1. Delete the old Gateway resource: `kubectl delete gateway gateway-default -n openchoreo-data-plane`
2. Install the new gateway controller
3. Create the GatewayClass for the new controller
4. Update the data plane Helm chart with the new `gatewayClassName`
5. Grant RBAC for the new CRDs
6. Apply the new trait definition

Existing components keep working because the control plane renders standard HTTPRoutes regardless of which gateway controller handles them.

## Per-environment customization

Trait parameters can be overridden per environment via ReleaseBinding:

```yaml
spec:
  traitOverrides:
    my-api-config:
      rateLimiting:
        requestsPerUnit: 600    # production override
```

This lets you have different rate limits, auth policies, or header rules per environment without changing the component definition.

## Module reference

Each module's README in the community-modules repo has complete setup instructions, prerequisites, and architecture details. Check there for module-specific configuration.
