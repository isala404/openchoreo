# OpenChoreo Concepts

OpenChoreo is an open-source Internal Developer Platform (IDP) built on Kubernetes. Developers interact through the `occ` CLI and never need direct cluster access. The platform abstracts away Kubernetes complexity while platform engineers control what's available.

## Resource Hierarchy

```
Namespace (tenant boundary)
  ├── Project (bounded context / app domain)
  │     ├── Component (deployable unit)
  │     │     ├── Workload (runtime spec: image, ports, env, connections)
  │     │     ├── ComponentRelease (immutable snapshot)
  │     │     └── ReleaseBinding (deploys release to environment)
  │     └── WorkflowRun (build execution)
  ├── Environment (dev/staging/prod, maps to DataPlane)
  ├── DeploymentPipeline (promotion paths between environments)
  └── SecretReference (external secret pointers)

Platform-managed (read-only for developers):
  ├── DataPlane (runtime cluster)
  ├── BuildPlane (CI/build cluster)
  ├── ObservabilityPlane (logging)
  ├── ComponentType / ClusterComponentType (deployment templates)
  ├── Trait / ClusterTrait (composable capabilities)
  └── Workflow (build/automation templates)
```

## Core Abstractions

### Project
A bounded context grouping related components. At runtime, each Project becomes a **Cell** with its own isolated namespace, network policies (Cilium), and security controls.

Components within a project communicate freely. Cross-project communication requires gateways, which platform engineers configure.

**Example**: An e-commerce app might have "order-management" (order-service, payment-handler) and "user-management" (auth-service, profile-service) as separate projects.

### Component
A deployable unit. References a ComponentType that defines how it's deployed. Think of ComponentType as the blueprint and Component as a specific house built from it.

**Key fields**:
- `componentType`: Reference like `deployment/service` (format: `workloadType/typeName`)
- `owner.projectName`: Which project this belongs to
- `parameters`: Config values matching the ComponentType schema
- `traits`: Optional composable capabilities
- `autoDeploy`: When true, automatically creates releases when Workload changes
- `workflow`: Build configuration for source-to-image on current Component resources

**Example**: Each microservice, web frontend, or background job is a separate component.

### Workload
The runtime contract. Defines what image to run, what ports to expose, and what services to connect to. Created automatically by source builds or manually for pre-built images (BYOI).

**Key fields**:
- `container`: image, command, args, env vars, files
- `endpoints`: Named network interfaces with type and visibility
- `connections`: Dependencies on other services with automatic env var injection

### Workload Descriptor
A `workload.yaml` file placed in your source repository that tells the build workflow what endpoints, connections, and configurations your service has. The build process reads this and generates a proper Workload CR.

**Placement**: Must be at the root of the `appPath` directory. If `appPath` is `/backend`, place it at `/backend/workload.yaml`. Not the docker context root, not the repo root (unless appPath is `.`).

See `deployment-guide.md` for the full descriptor schema.

### Endpoint Visibility
Controls who can reach your service:
- `project`: Same project and environment (implicit for all endpoints, no gateway needed)
- `namespace`: All projects in same namespace and environment (needs westbound gateway)
- `internal`: All namespaces in deployment (needs westbound gateway)
- `external`: Public internet (needs northbound gateway, usually configured)

The northbound gateway for external traffic is typically set up. The westbound gateway for internal/namespace traffic may not be. If you need internal visibility and get rendering errors, it's likely because the westbound gateway isn't configured. Escalate to platform engineering.

### ComponentType
Platform-engineer-defined template that controls how a component deploys. Developers pick from available types and fill in the schema. You can view available types with `occ clustercomponenttype list` and inspect one with `occ clustercomponenttype get <name>`.

**Workload types**: `deployment`, `statefulset`, `cronjob`, `job`, `proxy`

**Two kinds of parameters**:
- `parameters`: Static config, same everywhere the release deploys (e.g., image pull policy)
- `envOverrides`: The per-environment part of the ComponentType schema

ReleaseBinding supplies the actual per-environment values for that schema under `componentTypeEnvOverrides`.

### Trait
Composable capability attached to components. Adds resources (like PVCs) or modifies existing ones (inject env vars, add volumes) without changing the ComponentType.

Each trait instance on a component needs a unique `instanceName`. This lets you attach the same trait type multiple times with different configs (e.g., two different persistent volumes).

View available traits: `occ clustertrait list`, `occ trait list`
Inspect a trait: `occ clustertrait get <name>`

**Common traits**: persistent-volume, ingress, autoscaling, resource-limits

### Environment
A deployment target (dev, staging, prod). Maps to a DataPlane (Kubernetes cluster). View with `occ environment list`.

### DeploymentPipeline
Defines promotion paths between environments. A pipeline might be: development -> staging -> production.

**Important**: `deploymentPipelineRef` in Project spec is a plain string, not an object.
```yaml
# Correct
deploymentPipelineRef: default

# Wrong - will fail with unmarshal error
deploymentPipelineRef:
  kind: DeploymentPipeline
  name: default
```

### ComponentRelease
Immutable snapshot of Component + Workload + ComponentType + Traits at a point in time. Like a lock file for deployments. Created automatically when `autoDeploy: true`, or manually with `occ component deploy`.

### ReleaseBinding
Binds a ComponentRelease to an Environment. This is what triggers actual deployment. Supports environment-specific overrides:
- `componentTypeEnvOverrides`: Replicas, resource limits, etc.
- `traitOverrides`: Per-environment trait values keyed by trait instanceName
- `workloadOverrides`: Extra env vars, files for specific environments
- `state`: `Active` (running) or `Undeploy` (removed)

### Workflow / WorkflowRun
Workflow is a build template defined by platform engineers (backed by Argo Workflows). WorkflowRun is an execution. Component workflows build container images from source; standalone workflows handle automation like migrations.

**How CI builds work**: When you trigger a build, the workflow clones your repo, builds the image, then runs `occ workload create` with your `workload.yaml` descriptor to produce a Workload CR. The controller picks this up and creates/updates the Workload resource. If `autoDeploy` is on, this automatically triggers a new release and deployment. See `deployment-guide.md` for the full pipeline flow.

**Why workload.yaml exists**: A Dockerfile only describes how to build an image. It doesn't tell the platform what ports your app listens on, what protocol it speaks, or what other services it connects to. The `workload.yaml` descriptor fills this gap, declaring your app's runtime contract so the platform can generate the right routing, network policies, and service discovery.

### SecretReference
Points to secrets stored in an external secret store (like OpenBao or HashiCorp Vault). The platform syncs them into Kubernetes Secrets via External Secrets Operator. Used in Workload env vars via `secretRef`.

## Cell Architecture (Runtime)

At runtime, each Project becomes a Cell. Traffic between cells flows through directional gateways:
- **Northbound**: Ingress from public internet -> maps to `external` endpoint visibility
- **Southbound**: Egress to external services
- **Westbound**: Ingress from other cells within the org -> maps to `internal`/`namespace` visibility
- **Eastbound**: Egress to other cells

As a developer, you control this through endpoint `visibility` on Workloads. The gateways themselves are configured by platform engineers on the DataPlane.

## Deployment Flow

```
Component -> Workload -> ComponentRelease -> ReleaseBinding -> Release (on DataPlane)
```

1. Define Component (what to deploy, which type)
2. Define Workload (image, ports, connections) - manually or via build
3. ComponentRelease is created (immutable snapshot)
4. ReleaseBinding deploys release to environment
5. Platform renders templates, creates Kubernetes resources

For `autoDeploy: true` components, steps 3-4 happen automatically when the Workload changes.

## Infrastructure Planes

These are platform-engineer managed. Developers see them as read-only.

- **Control Plane**: Runs OpenChoreo controllers and API server
- **Data Plane**: Runs application workloads (can be multiple clusters)
- **Build Plane**: Runs CI/CD builds (Argo Workflows)
- **Observability Plane**: Centralized logging (OpenSearch + Fluentbit)

## API Version

All OpenChoreo resources use: `apiVersion: openchoreo.dev/v1alpha1`

## Inter-service Communication

Services within the same project can talk freely. For cross-project communication or formalized connections, use the Workload `connections` field instead of hardcoding URLs. The platform resolves service addresses and injects them as environment variables.

```yaml
connections:
  - component: backend-api
    endpoint: api
    visibility: project
    envBindings:
      address: BACKEND_URL
```

This injects `BACKEND_URL` with the resolved address. No hardcoded hostnames, no guessing service DNS names.
