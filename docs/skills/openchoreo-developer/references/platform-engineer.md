# Platform Engineer Abstractions

This reference covers what platform engineers manage. Developers don't create these resources directly, but understanding them helps when debugging issues or knowing what to escalate.

## Table of Contents

- [ComponentType Definition](#componenttype-definition)
- [Trait Definition](#trait-definition)
- [Workflow Definition](#workflow-definition)
- [Infrastructure Planes](#infrastructure-planes)
- [Gateway Configuration](#gateway-configuration)
- [Secret Store Setup](#secret-store-setup)
- [Registry Configuration](#registry-configuration)
- [Common Escalation Scenarios](#common-escalation-scenarios)

## ComponentType Definition

Platform engineers create ComponentTypes to define how components deploy. Each type specifies:

**Workload type**: `deployment`, `statefulset`, `cronjob`, `job`, or `proxy`

**Schema**: Defines what parameters developers can set.
```yaml
  schema:
    parameters:                      # static, same everywhere
      replicas: "integer | default=1"
      imagePullPolicy: "string | enum=Always,IfNotPresent,Never | default=IfNotPresent"
    envOverrides:                    # environment-specific schema; ReleaseBinding provides values via componentTypeEnvOverrides
      replicas: "integer | default=1 min=1 max=10"
      cpuLimit: "string | default=500m"
      memoryLimit: "string | default=256Mi"
```

Schema syntax: `"type | constraint1 constraint2"`
- Types: `string`, `integer`, `boolean`
- Constraints: `default=X`, `enum=A,B,C`, `min=N`, `max=N`

**Resource templates**: Kubernetes manifests with CEL expressions. Templates reference:
- `metadata.*` - component name, namespace, labels, environment name
- `parameters.*` - developer-provided static values
- `envOverrides.*` - environment-specific values from the ComponentType schema, populated by ReleaseBinding `componentTypeEnvOverrides`
- `workload.*` - container image, endpoints, connections
- `configurations.*` - config envs/files and secret envs/files
- `dataplane.*` - secretStore name, publicVirtualHost
- `gateway.ingress.*` - gateway names/namespaces, listener info

**Allowed workflows**: Explicit list of build workflows developers can use.

**Allowed traits**: List of traits developers can attach.

**Scope variants**:
- `ComponentType` - namespace-scoped, available within that namespace
- `ClusterComponentType` - cluster-scoped, available everywhere (can only reference ClusterTraits)

## Trait Definition

Traits augment components with operational behavior through two operations:

### Creates
Generate new Kubernetes resources (PVCs, ServiceMonitors, ExternalSecrets, etc.):
```yaml
creates:
  - targetPlane: dataplane          # or observabilityplane
    includeWhen: <CEL expression>   # conditional creation
    template:
      apiVersion: v1
      kind: PersistentVolumeClaim
      metadata:
        name: ${metadata.name}-${trait.instanceName}
```

### Patches
Modify existing ComponentType resources using JSON Patch (RFC 6902):
```yaml
patches:
  - target:
      kind: Deployment
      group: apps
      version: v1
    operations:
      - op: add
        path: /spec/template/spec/containers[?(@.name=='main')]/volumeMounts/-
        value:
          name: ${parameters.volumeName}
          mountPath: ${parameters.mountPath}
```

Patch operations: `add`, `replace`, `remove`
Array filtering: `[?(@.name=='app')]` targets specific elements

### Schema
Same structure as ComponentType: `parameters` (static) and `envOverrides` (per-environment schema values supplied through ReleaseBinding overrides).

**Scope variants**:
- `Trait` - namespace-scoped
- `ClusterTrait` - cluster-scoped

## Workflow Definition

Two CRDs for build automation:

### ComponentWorkflow
For building component source code into container images.

Required schema:
```yaml
schema:
  systemParameters:
    repository:
      url: 'string'
      secretRef: 'string'          # for private repos
      revision:
        branch: 'string | default=main'
        commit: 'string'
      appPath: 'string | default=.'
  parameters:                       # PE-defined build config
    docker-context: 'string | default=.'
    dockerfile-path: 'string | default=./Dockerfile'
```

The `runTemplate` contains an Argo Workflow with CEL expressions referencing `metadata.*`, `systemParameters.*`, `parameters.*`, and `secretRef.*`.

The build pipeline's last step is critical: a step named exactly `generate-workload-cr` with an output parameter named exactly `workload-cr`. The WorkflowRun controller watches for this convention. When it finds it, it reads the Workload CR YAML from the output and creates/updates the Workload resource in the control plane.

Inside this step, `occ workload create` merges the built image with the developer's `workload.yaml` descriptor (endpoints, connections, configurations) to produce a complete Workload CR. Without this step, builds produce images but the platform has no way to know how to deploy them.

```yaml
# In the ClusterWorkflowTemplate
- name: generate-workload-cr
  container:
    image: openchoreo-cli:latest
    command: [occ, workload, create]
    args:
      - --image={{steps.publish-image.outputs.parameters.image}}
      - --descriptor=workload.yaml
      - --output=/mnt/vol/workload-cr.yaml
  outputs:
    parameters:
      - name: workload-cr
        valueFrom:
          path: /mnt/vol/workload-cr.yaml
```

The controller adds a `WorkloadUpdated` condition to the WorkflowRun status to track whether this succeeded.

### Workflow
For standalone automation (database migrations, data processing, etc.). Similar structure but without systemParameters.

## Infrastructure Planes

### Control Plane
Runs OpenChoreo controllers and API server. Where the `occ` CLI connects to. Not directly configurable by developers.

### Data Plane
Kubernetes cluster where application workloads run.

Key configuration by PE:
- `planeID` - identifies the logical plane (must match cluster agent helm value)
- `clusterAgent.clientCA` - CA certificate for mTLS with agent
- `gateway.publicVirtualHost` - for external traffic routing
- `gateway.organizationVirtualHost` - for internal traffic
- `secretStoreRef` - reference to External Secrets Operator ClusterSecretStore
- `imagePullSecretRefs` - references for pulling from private registries
- `observabilityPlaneRef` - link to logging infrastructure

Multiple DataPlane CRs can share the same `planeID` for multi-tenancy.

### Build Plane
Kubernetes cluster for CI/CD execution (Argo Workflows).

Key configuration:
- `planeID` - must match cluster agent helm value
- `clusterAgent.clientCA` - mTLS auth
- `secretStoreRef` - for build secrets (registry creds, repo access)

### Observability Plane
Centralized logging via OpenSearch + Fluentbit. Enables `occ component logs`.

## Gateway Configuration

Gateways control traffic flow in and out of project cells.

**Northbound (external -> cell)**: Configured on the DataPlane. Enables endpoints with `visibility: "external"`. Usually configured in standard setups.

**Westbound (internal cell -> cell)**: Configured on the DataPlane. Enables endpoints with `visibility: "internal"` and `visibility: "namespace"`. May NOT be configured, especially in simple setups.

**Southbound (cell -> external)**: Egress control for outbound traffic.

**Eastbound (cell -> other cells)**: Egress to other internal cells.

If endpoints with `internal` or `namespace` visibility cause rendering errors, the westbound gateway likely isn't configured on the DataPlane. This requires PE intervention.

## Secret Store Setup

OpenChoreo uses External Secrets Operator to sync secrets from external stores.

**ClusterSecretStore**: Configured on the DataPlane cluster, referenced by DataPlane CR's `secretStoreRef`. Common backends: OpenBao (dev), HashiCorp Vault, AWS Secrets Manager, GCP Secret Manager.

**SecretReference**: Developer-facing resource that maps external secrets to Kubernetes Secrets. References the ClusterSecretStore configured on the DataPlane.

If developers need to use secrets and there's no ClusterSecretStore configured, they need PE help to set one up.

## Registry Configuration

For pulling from private container registries:

1. PE stores registry credentials in the secret store
2. PE adds an ExternalSecret resource to the ComponentType that syncs credentials
3. PE adds `imagePullSecrets` to the Deployment template in the ComponentType
4. PE references the SecretReference in the DataPlane's `imagePullSecretRefs`

Developers can't configure this themselves. The ComponentType must be set up to support private registries.

## Common Escalation Scenarios

When you hit something that requires PE help, here's what's likely needed:

### Missing ComponentType
"We need a ComponentType for [use case]. The available types don't support [requirement]. Can the PE team create a `[workloadType]/[name]` ComponentType with [specific schema needs]?"

### Missing Trait
"We need a trait that provides [capability]. For example, [concrete use case]. Can the PE team create a Trait that [does X]?"

### Internal Gateway Not Configured
"Inter-service communication across projects needs the westbound gateway. We're getting rendering errors when using `internal` or `namespace` endpoint visibility. Can the PE team configure the westbound gateway on the DataPlane?"

### Private Registry Access
"We need to pull images from [registry]. This requires imagePullSecrets configured in the ComponentType and credentials stored in the secret backend. Can the PE team set this up?"

### Secret Store Not Available
"We need to use secrets (for [purpose]) but there's no ClusterSecretStore configured on the DataPlane. Can the PE team set one up?"

### New Environment Needed
"We need a [staging/production] environment for [reason]. Can the PE team create an Environment resource pointing to the appropriate DataPlane?"

### Build Plane Issues
"Builds aren't running. This usually means the BuildPlane isn't configured or the agent isn't connected. Can the PE team check the BuildPlane status and agent connectivity?"

### Custom Workflow Needed
"We need a build workflow that [does X differently from existing workflows]. Can the PE team create a ComponentWorkflow with [requirements]?"

### Observability Not Working
"Application logs aren't available through `occ component logs`. Can the PE team verify the ObservabilityPlane is configured and Fluentbit agents are running?"
