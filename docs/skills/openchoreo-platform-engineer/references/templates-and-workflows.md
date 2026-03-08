# Templates and Workflows

## Table of Contents

- [ComponentType Authoring](#componenttype-authoring)
- [Trait Authoring](#trait-authoring)
- [Workflow Authoring](#workflow-authoring)
- [CEL Expression Context](#cel-expression-context)

## ComponentType Authoring

ComponentTypes define how components deploy. Each type specifies a workload kind, a schema for developer-facing parameters, and Kubernetes resource templates.

### Structure

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ComponentType               # or ClusterComponentType
metadata:
  name: service
  namespace: default              # omit for ClusterComponentType
spec:
  workloadType: deployment        # deployment | statefulset | cronjob | job | proxy
  allowedWorkflows:
    - kind: Workflow
      name: docker
    - kind: Workflow
      name: google-cloud-buildpacks
  allowedTraits:
    - kind: Trait                  # or ClusterTrait for ClusterComponentType
      name: persistent-volume
  schema:
    parameters:                   # static, same across all environments
      replicas: "integer | default=1"
      imagePullPolicy: "string | enum=Always,IfNotPresent,Never | default=IfNotPresent"
    envOverrides:                 # per-environment schema; ReleaseBinding provides values via componentTypeEnvOverrides
      replicas: "integer | default=1 min=1 max=10"
      cpuLimit: "string | default=500m"
      memoryLimit: "string | default=256Mi"
  resources:
    - id: deployment
      template:
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: ${metadata.name}
          namespace: ${metadata.namespace}
        spec:
          replicas: ${envOverrides.replicas}
          selector:
            matchLabels:
              app: ${metadata.name}
          template:
            metadata:
              labels:
                app: ${metadata.name}
            spec:
              containers:
                - name: main
                  image: ${workload.container.image}
                  resources:
                    limits:
                      cpu: ${envOverrides.cpuLimit}
                      memory: ${envOverrides.memoryLimit}
```

### Schema syntax

Format: `"type | constraint1 constraint2"`

Types: `string`, `integer`, `boolean`

Constraints:
- `default=X` - default value
- `enum=A,B,C` - allowed values
- `min=N`, `max=N` - range for integers

### Scope rules

- `ClusterComponentType` is cluster-scoped, available in all namespaces. Can only reference `ClusterTrait` in `allowedTraits`.
- `ComponentType` is namespace-scoped. Can reference either `Trait` or `ClusterTrait`.

### Validation

ComponentType and ClusterComponentType have admission webhooks that validate:
- Schema syntax is correct
- CEL expressions in templates are valid
- Referenced traits and workflows exist
- Workload type is valid

## Trait Authoring

Traits augment components through two operations: creating new resources and patching existing ones.

### Creates

Generate new Kubernetes resources (PVCs, ExternalSecrets, ServiceMonitors, etc.):

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: Trait                        # or ClusterTrait
metadata:
  name: persistent-volume
spec:
  schema:
    parameters:
      volumeName: "string"
      mountPath: "string"
      containerName: "string | default=main"
    envOverrides:
      size: "string | default=10Gi"
      storageClass: "string | default=standard"
  creates:
    - targetPlane: dataplane       # or observabilityplane
      includeWhen: "true"          # CEL expression, optional
      template:
        apiVersion: v1
        kind: PersistentVolumeClaim
        metadata:
          name: ${metadata.name}-${trait.instanceName}
          namespace: ${metadata.namespace}
        spec:
          accessModes: ["ReadWriteOnce"]
          storageClassName: ${envOverrides.storageClass}
          resources:
            requests:
              storage: ${envOverrides.size}
```

`includeWhen` controls conditional creation via CEL. The resource is only created when the expression evaluates to true.

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
          path: /spec/template/spec/volumes/-
          value:
            name: ${parameters.volumeName}
            persistentVolumeClaim:
              claimName: ${metadata.name}-${trait.instanceName}
        - op: add
          path: /spec/template/spec/containers[?(@.name=='${parameters.containerName}')]/volumeMounts/-
          value:
            name: ${parameters.volumeName}
            mountPath: ${parameters.mountPath}
```

Patch operations: `add`, `replace`, `remove`

Array filtering: `[?(@.name=='value')]` targets specific array elements by field value.

### Instance names

Each trait attachment on a component needs a unique `instanceName`. This lets developers attach the same trait type multiple times with different configs (two volumes, two alert rules, etc.).

## Workflow Authoring

### Component Workflows

For building source code into container images. The key convention: the last step must be named `generate-workload-cr` with an output parameter named `workload-cr`.

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: Workflow
metadata:
  name: docker
  namespace: default
  annotations:
    openchoreo.dev/workflow-scope: "component"
    openchoreo.dev/component-workflow-parameters: |
      {
        "repository.url": "systemParameters.repository.url",
        "repository.revision.branch": "systemParameters.repository.revision.branch"
      }
spec:
  schema:
    systemParameters:
      repository:
        url: 'string'
        secretRef: 'string'
        revision:
          branch: 'string | default=main'
          commit: 'string'
        appPath: 'string | default=.'
    parameters:
      docker-context: 'string | default=.'
      dockerfile-path: 'string | default=./Dockerfile'
  externalRefs:
    - name: registry-push-secret
      secretRef:
        name: registry-push-secret
  runTemplate:
    # Argo Workflow spec with CEL expressions
    # References: ${metadata.*}, ${systemParameters.*}, ${parameters.*}, ${secretRef.*}
```

### The generate-workload-cr step

This is the bridge between builds and deployments. The WorkflowRun controller watches for this step name and output parameter. When it finds them, it reads the Workload CR YAML from the output and creates/updates the Workload resource.

```yaml
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

Without this step, builds produce images but the platform has no way to create Workloads from them.

### Standalone Workflows

For automation (migrations, data processing). Same structure but without `systemParameters` and without the `component` workflow scope annotation.

### Workflow resources

Workflows can include additional Kubernetes resources that get created alongside the workflow run:

```yaml
spec:
  resources:
    - includeWhen: "${externalRefs.registry-push-secret != ''}"
      template:
        apiVersion: external-secrets.io/v1
        kind: ExternalSecret
        # ...
```

## CEL Expression Context

All CEL expressions in ComponentType, Trait, and Workflow templates have access to these context variables:

| Variable | Available in | Description |
|----------|-------------|-------------|
| `metadata.name` | All | Resource name |
| `metadata.namespace` | All | Resource namespace |
| `metadata.labels.*` | All | Resource labels |
| `metadata.environmentName` | All | Target environment name |
| `parameters.*` | ComponentType, Trait | Static developer parameters |
| `envOverrides.*` | ComponentType, Trait | Per-environment schema values populated from ReleaseBinding overrides |
| `workload.container.*` | ComponentType | Container image, command, args, env |
| `workload.endpoints.*` | ComponentType | Endpoint definitions |
| `configurations.*` | ComponentType | Config envs/files and secret envs/files |
| `dataplane.secretStore` | ComponentType | Secret store name from DataPlane |
| `dataplane.publicVirtualHost` | ComponentType | Public host from DataPlane gateway |
| `gateway.ingress.*` | ComponentType | Gateway names, namespaces, listeners |
| `trait.instanceName` | Trait | The instance name of the trait attachment |
| `systemParameters.*` | Workflow | Repository URL, revision, appPath |
| `secretRef.*` | Workflow | Resolved external secret references |
