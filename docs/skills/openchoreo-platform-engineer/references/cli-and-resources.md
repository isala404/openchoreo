# CLI and Resources

## PE-Relevant occ Commands

PEs use both `occ` and `kubectl`. Use `occ` for OpenChoreo abstractions, `kubectl` for cluster-level operations and debugging.

### Quick reference

| Command | Alias | What it does |
|---------|-------|-------------|
| `occ dataplane list/get` | `dp` | Inspect DataPlane CRs |
| `occ buildplane list/get` | `bp` | Inspect BuildPlane CRs |
| `occ observabilityplane list/get` | `op` | Inspect ObservabilityPlane CRs |
| `occ environment list/get` | `env` | Inspect Environments |
| `occ deploymentpipeline list/get` | `deppipe` | Inspect promotion paths |
| `occ componenttype list/get` | `ct` | Inspect namespace-scoped types |
| `occ clustercomponenttype list/get` | `cct` | Inspect cluster-scoped types |
| `occ trait list/get` | `traits` | Inspect namespace-scoped traits |
| `occ clustertrait list/get` | `clustertraits` | Inspect cluster-scoped traits |
| `occ workflow list/get` | `wf` | Inspect workflow templates |
| `occ authzclusterrole list/get` | `cr` | Inspect cluster roles |
| `occ authzclusterrolebinding list/get` | `crb` | Inspect cluster role bindings |
| `occ authzrole list/get` | - | Inspect namespace roles |
| `occ authzrolebinding list/get` | `rb` | Inspect role bindings |
| `occ apply -f <file>` | - | Create/update any resource |
| `occ namespace list/get` | `ns` | Inspect namespaces |

### Key behaviors

- `occ <resource> get <name>` returns full YAML (spec + status). No `-o` flag.
- Scope flags are not uniform across `occ` subcommands. Many `list` commands accept `--project`, while many `get` commands use `--namespace` only. Check `--help` on the exact subcommand when scope matters.
- `occ apply -f` works for all resource types including platform resources.
- Service account login: `occ login --client-credentials --client-id <id> --client-secret <secret>`

## Resource Schemas

### DataPlane

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: DataPlane                     # also ClusterDataPlane
metadata:
  name: default
  namespace: default
spec:
  planeID: default                  # must match agent Helm value
  clusterAgent:
    clientCA:
      value: |                      # agent's CA certificate (PEM)
        -----BEGIN CERTIFICATE-----
        ...
        -----END CERTIFICATE-----
  gateway:
    publicVirtualHost: "apps.example.com"
    organizationVirtualHost: "internal.example.com"
    publicHTTPPort: 80
    publicHTTPSPort: 443
    ingress:
      external:
        name: gateway-default
        namespace: openchoreo-data-plane
        http:
          host: openchoreoapis.localhost
          port: 19080
          listenerName: http
  secretStoreRef:
    name: default
  imagePullSecretRefs:
    - name: registry-credentials
  observabilityPlaneRef:
    name: default
```

### BuildPlane

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: BuildPlane                    # also ClusterBuildPlane
metadata:
  name: default
  namespace: default
spec:
  planeID: default
  clusterAgent:
    clientCA:
      value: |
        -----BEGIN CERTIFICATE-----
        ...
        -----END CERTIFICATE-----
  secretStoreRef:
    name: default
```

### ObservabilityPlane

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ObservabilityPlane            # also ClusterObservabilityPlane
metadata:
  name: default
  namespace: default
spec:
  planeID: default
  clusterAgent:
    clientCA:
      value: |
        -----BEGIN CERTIFICATE-----
        ...
        -----END CERTIFICATE-----
  observerURL: "https://observer.example.com"
```

### Environment

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: Environment
metadata:
  name: development
  namespace: default
  labels:
    openchoreo.dev/name: development
spec:
  dataPlaneRef:
    kind: DataPlane
    name: default
  isProduction: false
```

### DeploymentPipeline

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: DeploymentPipeline
metadata:
  name: default
  namespace: default
spec:
  promotionPaths:
    - sourceEnvironmentRef: development
      targetEnvironmentRefs:
        - name: staging
          requiresApproval: false
    - sourceEnvironmentRef: staging
      targetEnvironmentRefs:
        - name: production
          requiresApproval: true
```

### Project

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: Project
metadata:
  name: default
  namespace: default
spec:
  deploymentPipelineRef: default     # plain string, not an object
```

### ObservabilityAlertsNotificationChannel

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ObservabilityAlertsNotificationChannel
metadata:
  name: email-alerts
  namespace: default
spec:
  environment: development
  isEnvDefault: true
  type: email                        # email | webhook
  emailConfig:
    from: alerts@example.com
    to: ["team@example.com"]
    smtp:
      host: smtp.example.com
      port: 587
      auth:
        username:
          secretKeyRef: {name: smtp-creds, key: username}
        password:
          secretKeyRef: {name: smtp-creds, key: password}
```

For ComponentType, Trait, and Workflow schemas, see `templates-and-workflows.md`.
