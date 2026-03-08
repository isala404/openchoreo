# Repository Lookup and Context7

When the operational docs don't cover something, look up OpenChoreo internals from the source repo.

## Context7 API

Use the Context7 API to pull current documentation and code snippets from the OpenChoreo repository. No API key needed.

### Find the OpenChoreo library ID

```bash
curl -s "https://context7.com/api/v2/libs/search?libraryName=openchoreo&query=openchoreo" | jq '.results[0]'
```

This returns an `id` field (something like `/openchoreo/openchoreo`) that you use in the next step.

### Fetch documentation by topic

```bash
curl -s "https://context7.com/api/v2/context?libraryId=LIBRARY_ID&query=TOPIC&type=txt"
```

Replace `LIBRARY_ID` with the id from step 1 and `TOPIC` with what you're looking for.

### Example queries a PE might run

```bash
# How does the DataPlane controller reconcile?
curl -s "https://context7.com/api/v2/context?libraryId=/openchoreo/openchoreo&query=dataplane+controller+reconcile&type=txt"

# What fields does ClusterDataPlane support?
curl -s "https://context7.com/api/v2/context?libraryId=/openchoreo/openchoreo&query=ClusterDataPlane+types&type=txt"

# How does the cluster gateway mTLS work?
curl -s "https://context7.com/api/v2/context?libraryId=/openchoreo/openchoreo&query=cluster+gateway+mtls+certificate&type=txt"

# What Helm values does the control plane chart accept?
curl -s "https://context7.com/api/v2/context?libraryId=/openchoreo/openchoreo&query=helm+values+control+plane&type=txt"

# How does ComponentType template rendering work?
curl -s "https://context7.com/api/v2/context?libraryId=/openchoreo/openchoreo&query=componenttype+template+rendering+CEL&type=txt"

# WorkflowRun controller and generate-workload-cr
curl -s "https://context7.com/api/v2/context?libraryId=/openchoreo/openchoreo&query=workflowrun+controller+generate+workload&type=txt"
```

Use `type=txt` for readable output. Use `jq` if you need to filter JSON responses.

## OpenChoreo MCP Server

OpenChoreo also exposes platform operations via a built-in MCP server alongside the API:

```
http://<openchoreo-api-domain>/mcp
```

Local quick-start: `http://api.openchoreo.localhost:8080/mcp`

Requires a Bearer token from Thunder (`http://thunder.openchoreo.localhost:8080/develop`) or your configured OAuth2 provider.

Available toolsets (controlled via `MCP_TOOLSETS` env var):

| Toolset | Covers |
|---------|--------|
| `namespace` | list/create namespaces, secret references |
| `project` | list/create projects |
| `component` | components, releases, workloads, workflows (36+ tools) |
| `infrastructure` | environments, deployment pipelines, observer URLs |
| `pe` | environments, planes, cluster resources |

## Direct repository reference

When neither Context7 nor MCP is available, here's where to find things in the `openchoreo/openchoreo` repo:

### CRD type definitions

All at `api/v1alpha1/`:

| File | Types |
|------|-------|
| `dataplane_types.go` | DataPlane, GatewaySpec, SecretStoreRef |
| `clusterdataplane_types.go` | ClusterDataPlane |
| `buildplane_types.go` | BuildPlane |
| `clusterbuildplane_types.go` | ClusterBuildPlane |
| `observabilityplane_types.go` | ObservabilityPlane |
| `clusterobservabilityplane_types.go` | ClusterObservabilityPlane |
| `componenttype_types.go` | ComponentType |
| `clustercomponenttype_types.go` | ClusterComponentType |
| `trait_types.go` | Trait |
| `clustertrait_types.go` | ClusterTrait |
| `workflow_types.go` | Workflow |
| `workflowrun_types.go` | WorkflowRun |
| `environment_types.go` | Environment |
| `deploymentpipeline_types.go` | DeploymentPipeline |
| `deploymenttrack_types.go` | DeploymentTrack |
| `component_types.go` | Component |
| `workload_types.go` | Workload |
| `release_types.go` | ComponentRelease |
| `releasebinding_types.go` | ReleaseBinding |
| `secretreference_types.go` | SecretReference |

### Controllers

All at `internal/controller/<name>/controller.go`:

PE-relevant: `dataplane`, `clusterdataplane`, `buildplane`, `clusterbuildplane`, `observabilityplane`, `clusterobservabilityplane`, `componenttype`, `clustercomponenttype`, `trait`, `clustertrait`, `workflow`, `environment`, `deploymentpipeline`

### Helm charts

- Control Plane: `install/helm/openchoreo-control-plane/`
  - `values.yaml` - all config options
  - `values.schema.json` - validation schema
  - `crds/` - all CRD manifests
- Quick-start: `install/quick-start/`

### ClusterWorkflowTemplates

Build workflow Argo templates live on the Build Plane cluster:

```bash
kubectl get clusterworkflowtemplates
kubectl get clusterworkflowtemplate <name> -o yaml
```

Key templates: `publish-image`, `docker-build`, `buildpacks`, `generate-workload`

### Related repositories

| Repository | What it contains |
|-----------|-----------------|
| `openchoreo/openchoreo` | Core platform: CRDs, controllers, API, CLI, Helm charts |
| `openchoreo/sample-gitops` | Reference GitOps repo with Flux setup, platform resources, release workflows |
| `openchoreo/sample-workloads` | Example apps (Go, Python, React, Ballerina) with workload.yaml descriptors |
| `openchoreo/community-modules` | Pluggable gateway and observability modules |
