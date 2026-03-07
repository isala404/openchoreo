# Deploying Applications to OpenChoreo

## Pre-built Image (BYOI) - Simplest Path

For apps with existing container images, you need Component + Workload resources.

### Minimal Example

```yaml
---
apiVersion: openchoreo.dev/v1alpha1
kind: Component
metadata:
  name: my-app
  namespace: default
spec:
  autoDeploy: true
  componentType:
    kind: ComponentType        # or ClusterComponentType
    name: deployment/service   # format: workloadType/typeName
  owner:
    projectName: default
  parameters: {}
---
apiVersion: openchoreo.dev/v1alpha1
kind: Workload
metadata:
  name: my-app-workload
  namespace: default
spec:
  owner:
    componentName: my-app
    projectName: default
  container:
    image: "myregistry/my-app:v1.0.0"
    env:
      - key: PORT
        value: "8080"
  endpoints:
    http:
      port: 8080
      type: REST
      visibility: ["external"]
```

Apply: `occ apply -f my-app.yaml`

### With Traits

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: Component
metadata:
  name: my-app
  namespace: default
spec:
  autoDeploy: true
  componentType:
    name: deployment/service
  owner:
    projectName: default
  parameters: {}
  traits:
    - name: persistent-volume
      kind: Trait              # or ClusterTrait
      instanceName: data-storage
      parameters:
        volumeName: data
        mountPath: /var/data
        containerName: app
```

## Building from Source

For source-to-image builds, configure a Workflow on the Component. The exact workflow name and parameter schema come from the cluster, so inspect `occ workflow list` and `occ workflow get <name>` or use a matching sample from `samples/from-source/`.

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: Component
metadata:
  name: my-app
  namespace: default
spec:
  owner:
    projectName: default
  componentType:
    name: deployment/service
  autoDeploy: true
  workflow:
    name: docker
    parameters:
      scope:
        projectName: "default"
        componentName: "my-app"
      repository:
        url: "https://github.com/myorg/my-app"
        revision:
          branch: "main"
        appPath: "."
      docker:
        context: "."
        filePath: "./Dockerfile"
```

Trigger builds: `occ component workflow run my-app`
Follow build logs: `occ component workflow logs my-app -f`

**Important path rule for multi-directory repos**: `repository.appPath` tells the workflow where the service source lives and where to find `workload.yaml`, but Docker workflow paths still need to match the actual repo layout. If the service lives under `backend/` with `backend/Dockerfile`, use `docker.context: ./backend` and `docker.filePath: ./backend/Dockerfile` or the equivalent leading-slash form used by repo samples. Do not assume `appPath: ./backend` makes `./Dockerfile` resolve inside that directory.

**Important project rule for source builds**: Keep `spec.owner.projectName`, `spec.workflow.parameters.scope.projectName`, and the active `occ` context project aligned. If the workflow scope still points at `default`, the build can generate a Workload owned by the wrong project even when the Component itself lives in the right project.

## How the CI Pipeline Works

Understanding the build flow helps debug issues and explains why `workload.yaml` exists.

### The Problem workload.yaml Solves

A Dockerfile tells you how to build an image, but it doesn't tell the platform anything about your application's runtime needs: what ports it listens on, what protocol it speaks (REST vs gRPC), what other services it connects to, or what visibility its endpoints need. The platform needs this information to generate the right Kubernetes resources (Services, HTTPRoutes, network policies, env var injection for connections).

The `workload.yaml` descriptor bridges this gap. It's a declaration of your app's runtime contract that lives alongside your source code.

### Build Pipeline Flow

When you trigger a build (`occ component workflow run my-app`), here's what happens:

```
1. Source checkout
   └── Clone repo, check out branch/commit

2. Build image
   └── Run Dockerfile (or buildpack), push image to registry

3. Generate Workload CR  (the key step)
   └── Run `occ workload create` with:
       - The built image reference from step 2
       - The workload.yaml descriptor from your source (if present)
       - Component/project context
   └── Outputs a complete Workload CR YAML

4. Controller picks up the Workload CR
   └── Creates or updates the Workload resource in the control plane
   └── If autoDeploy is true, this triggers a new ComponentRelease and deployment
```

### The generate-workload-cr Step

The build workflow (an Argo Workflow) has a special step named `generate-workload-cr`. The WorkflowRun controller watches for this specific step name and reads its output parameter `workload-cr`.

Inside this step, `occ workload create` runs:
```
occ workload create \
  --image <built-image-from-previous-step> \
  --descriptor workload.yaml \
  --output /mnt/vol/workload-cr.yaml
```

This reads your `workload.yaml`, merges it with the built image reference, and produces a full Workload CR. The controller then creates or updates the Workload in the control plane.

**With descriptor**: The Workload CR gets endpoints, connections, configurations, and the image. The platform knows how to route traffic, inject connection env vars, and configure networking.

**Without descriptor**: The Workload CR gets just the container image. No endpoints, no connections, no special configuration. The component deploys but the platform can't set up routing or service discovery for it.

### What This Means for You

- If your service exposes APIs or needs to talk to other services, you need a `workload.yaml`
- If it's a simple worker with no network exposure, you might skip it
- The descriptor must be at the `appPath` root so the build step can find it
- Build logs (`occ component workflow logs my-app -f`) show whether the descriptor was found and processed
- After a successful build, check `occ workload get <name>` to verify endpoints and connections made it through

## Workload Descriptor (workload.yaml)

When building from source, place a `workload.yaml` at the root of the `appPath` directory. This tells the build workflow what endpoints, connections, and configurations your service has.

**Placement rules**:
- If `appPath: .` -> `workload.yaml` at repo root
- If `appPath: ./backend` -> `backend/workload.yaml`
- File must be named exactly `workload.yaml` (not `.workload.yaml`, not `Workload.yaml`)
- This is at the `appPath` root, not the docker context root

### Full Descriptor Schema

```yaml
apiVersion: openchoreo.dev/v1alpha1

metadata:
  name: my-service              # descriptive name for the workload

endpoints:
  - name: api                   # unique endpoint name
    port: 8080                  # exposed port (required)
    type: REST                  # HTTP, REST, gRPC, GraphQL, Websocket, TCP, UDP
    targetPort: 8080            # container port (defaults to port)
    displayName: "REST API"     # human-readable name
    basePath: "/api/v1"         # URL path prefix
    schemaFile: openapi.yaml    # relative path to schema file (read and inlined)
    visibility:                 # additional scopes beyond implicit "project"
      - external

connections:
  - component: backend-api      # target component name (required)
    endpoint: api               # target endpoint name (required)
    visibility: project         # project, namespace, or internal (required)
    project: other-project      # target project (optional, defaults to same project)
    envBindings:                # env vars injected with resolved addresses
      address: BACKEND_URL      # full connection string
      host: BACKEND_HOST        # hostname only
      port: BACKEND_PORT        # port number only
      basePath: BACKEND_PATH    # base path only

configurations:
  env:
    - name: LOG_LEVEL
      value: info               # literal value
    - name: DB_PASSWORD
      valueFrom:
        secretKeyRef:
          name: db-secrets      # SecretReference name
          key: password
  files:
    - name: config.json
      mountPath: /etc/config/config.json
      value: |                  # inline file content
        {"debug": false}
    - name: cert.pem
      mountPath: /etc/ssl/cert.pem
      valueFrom:
        secretKeyRef:
          name: tls-certs
          key: cert
```

### Endpoint Types
HTTP, REST, gRPC, GraphQL, Websocket, TCP, UDP

### Visibility Values
- `project` - implicit for all endpoints, no extra gateway needed
- `namespace` - needs westbound gateway
- `internal` - needs westbound gateway
- `external` - needs northbound gateway (usually configured)

### Connection EnvBindings
The platform resolves the target service address and injects env vars. Use connections instead of hardcoding URLs. At least one envBinding field should be set.

## Using occ component scaffold

The fastest way to create component YAML. Reads available types from the cluster and generates properly structured YAML.

```bash
# See what's available
occ clustercomponenttype list
occ componenttype list
occ clustertrait list
occ trait list

# Generate YAML (--type format is workloadType/typeName)
occ component scaffold my-app --type deployment/service -o my-app.yaml
occ component scaffold my-app --type deployment/web-application \
  --traits persistent-volume,ingress --workflow react -o my-app.yaml
```

The component name is positional. `occ component scaffold --name ...` is invalid.

## Deploying and Promoting

```bash
# Deploy latest release to root environment
occ component deploy my-app

# Promote to next environment
occ component deploy my-app --to staging
occ component deploy my-app --to production

# Deploy with env-specific overrides
occ component deploy my-app --to production \
  --set spec.componentTypeEnvOverrides.replicas=3
```

## ReleaseBinding with Overrides

For environment-specific configuration, create ReleaseBinding resources:

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ReleaseBinding
metadata:
  name: my-app-production
  namespace: default
spec:
  environment: production
  owner:
    componentName: my-app
    projectName: default
  componentTypeEnvOverrides:
    replicas: 3
  traitOverrides:
    data-storage:             # keyed by trait instanceName
      size: 100Gi
      storageClass: production-ssd
  workloadOverrides:
    container:
      env:
        - key: LOG_LEVEL
          value: warn
```

## Multi-Service Applications

Each service becomes its own Component. For a typical frontend + backend app:

1. **Backend**: `deployment/service` ComponentType, workload descriptor with API endpoints
2. **Frontend**: `deployment/web-application` ComponentType (or similar available type)
3. **Communication**: Use connections in the frontend's workload descriptor to reference the backend
4. **Workflow choice**: If a frontend uses a custom Dockerfile, nginx proxy, or custom runtime, prefer the `docker` workflow over `react`

For source builds with separate directories:

```
my-app/
├── backend/
│   ├── Dockerfile
│   ├── workload.yaml          # backend descriptor at appPath root
│   └── src/
└── frontend/
    ├── Dockerfile
    ├── workload.yaml          # frontend descriptor at appPath root
    └── src/
```

Backend component uses `appPath: ./backend`, frontend uses `appPath: ./frontend`.

Frontend's workload.yaml uses connections:
```yaml
connections:
  - component: backend-service
    endpoint: api
    visibility: project
    envBindings:
      host: BACKEND_HOST
      port: BACKEND_PORT
```

The platform injects the resolved backend host and port. This is safer for nginx-style reverse proxies because it avoids accidentally doubling a backend endpoint `basePath`.

## Environment Variables and Configuration

There are several ways to pass configuration to your app on OpenChoreo.

### Literal env vars in Workload

For non-sensitive config that's the same everywhere:
```yaml
# In Workload CR
container:
  env:
    - key: LOG_LEVEL
      value: info
    - key: APP_ENV
      value: production

# In workload.yaml descriptor
configurations:
  env:
    - name: LOG_LEVEL
      value: info
```

### Secrets via SecretReference

For sensitive values (API keys, database passwords, tokens). Never hardcode these.
```yaml
# 1. Create a SecretReference.
# The backing secret store must already be configured on the DataPlane by PE.
apiVersion: openchoreo.dev/v1alpha1
kind: SecretReference
metadata:
  name: my-secrets
  namespace: default
spec:
  template:
    type: Opaque
  data:
    - secretKey: db-password
      remoteRef:
        key: my-app/database
        property: password
  refreshInterval: 1h

# 2. Reference it in Workload
container:
  env:
    - key: DB_PASSWORD
      valueFrom:
        secretRef:
          name: my-secrets
          key: db-password

# Or in workload.yaml descriptor
configurations:
  env:
    - name: DB_PASSWORD
      valueFrom:
        secretKeyRef:
          name: my-secrets
          key: db-password
```

If there's no ClusterSecretStore configured, this needs PE help to set up.

### Per-environment overrides via ReleaseBinding

For config that differs between dev/staging/prod (replicas, log levels, feature flags):
```yaml
# workloadOverrides inject extra env vars for a specific environment
workloadOverrides:
  container:
    env:
      - key: LOG_LEVEL
        value: debug        # debug in dev, warn in prod
      - key: FEATURE_FLAG_X
        value: "true"

# componentTypeEnvOverrides for things in the ComponentType schema
componentTypeEnvOverrides:
  replicas: 3
  cpuLimit: "1000m"
```

### Connection-injected env vars

When using Workload connections, the platform automatically injects env vars with resolved service addresses. You control the env var names through `envBindings`:
```yaml
connections:
  - component: backend-api
    endpoint: api
    visibility: project
    envBindings:
      address: BACKEND_URL    # full connection string; may include endpoint basePath
      host: BACKEND_HOST      # e.g., backend-api
      port: BACKEND_PORT      # e.g., 8080
      basePath: BACKEND_PATH  # e.g., /api
```

Your app can read whichever form fits the integration point.

- For application code that wants the platform-resolved full upstream URL, `address` is convenient.
- For nginx or other reverse proxies that already own a path like `/api/`, prefer `host` and `port`, and handle `basePath` separately if needed. This avoids doubled paths such as `/api/api/...`.

### File-based configuration

For config files (JSON, YAML, certificates):
```yaml
# In Workload CR
container:
  files:
    - key: app-config
      mountPath: /etc/config/app.json
      value: |
        {"cache_ttl": 300, "max_connections": 50}

# In workload.yaml descriptor
configurations:
  files:
    - name: app-config
      mountPath: /etc/config/app.json
      value: |
        {"cache_ttl": 300, "max_connections": 50}
```

## Making Local Apps Work on OpenChoreo

The main challenge when moving from local development to OpenChoreo is how services find each other. Locally you use `localhost:PORT` or docker-compose service names. On OpenChoreo, the platform manages service discovery through connections and env vars.

The goal is to make apps work in both environments without separate codebases.

### The Pattern: Env Vars with Local Defaults

The universal solution is: read service URLs from environment variables, with fallback defaults for local development.

**Node.js / Express:**
```javascript
// Before (hardcoded, breaks on OpenChoreo)
const backendUrl = "http://localhost:3001";

// After (works everywhere)
const backendUrl = process.env.BACKEND_URL || "http://localhost:3001";
```

**Python / Flask / FastAPI:**
```python
# Before
BACKEND_URL = "http://localhost:3001"

# After
BACKEND_URL = os.environ.get("BACKEND_URL", "http://localhost:3001")
```

**Go:**
```go
// Before
backendURL := "http://localhost:3001"

// After
backendURL := os.Getenv("BACKEND_URL")
if backendURL == "" {
    backendURL = "http://localhost:3001"
}
```

On OpenChoreo, the `BACKEND_URL` env var is injected by the connection. Locally, the fallback kicks in.

### Frontend -> Backend Connectivity

Frontends are trickier because they run in the browser, not on the server. The browser can't read server-side env vars at runtime. Common patterns:

**Pattern 1: Build-time env vars (React, Vue, Angular)**

Inject the API base path at build time. Prefer same-origin `/api` as the default; that works locally when you have a proxy and avoids shipping `http://localhost...` into an HTTPS deployment.

```javascript
// Vite / modern frontend (.env.local for local dev if needed)
// .env.local
VITE_API_URL=/api

// In code
const apiUrl = import.meta.env.VITE_API_URL ?? "/api";
```

If you use a framework that exposes env vars differently, apply the same rule: default to `/api`, and use `??` or an explicit undefined check when an empty string is a meaningful value.

On OpenChoreo, the frontend's `workload.yaml` can set this via configurations:
```yaml
configurations:
  env:
    - name: VITE_API_URL
      value: /api    # relative path, proxied by the platform
```

**Pattern 2: Nginx reverse proxy (recommended for production)**

The frontend serves static files and proxies API calls to the backend. This avoids CORS entirely.

```nginx
# nginx.conf
server {
    listen 8080;

    location / {
        root /usr/share/nginx/html;
        try_files $uri $uri/ /index.html;
    }

    location /api/ {
        # Prefer host/port bindings so backend endpoint basePath does not get duplicated
        proxy_pass http://${BACKEND_HOST}:${BACKEND_PORT};
        proxy_set_header Host $host;
    }
}
```

The frontend code always calls `/api/...` (relative path). Nginx proxies it to wherever the backend is.

On OpenChoreo, the connection injects `BACKEND_HOST` and `BACKEND_PORT`. Locally, you set the same env vars in docker-compose or your run script.

**Pattern 3: Same-origin deployment**

If both frontend and backend are on the same domain (which OpenChoreo can do via basePath routing), the frontend just uses relative URLs like `/api/users`. No configuration needed.

### What to Look For When Scanning a Project

When preparing a local app for OpenChoreo, scan for these patterns:

**Hardcoded localhost URLs**: `http://localhost:`, `http://127.0.0.1:`, `http://0.0.0.0:`
- Replace with env var reads with the localhost value as default

**Docker-compose service names**: `http://backend:3001`, `http://db:5432`
- Replace with env var reads. On OpenChoreo, connections provide the actual addresses

**Hardcoded ports**: The app must listen on the port it declares in its endpoint
- Make the listen port configurable via env var (e.g., `PORT`)

**Hardcoded database connection strings**: `postgres://user:pass@localhost:5432/db`
- Move to env var, use SecretReference on OpenChoreo for credentials

**CORS configuration**: If frontend and backend are separate origins locally
- On OpenChoreo with proper basePath routing or proxy, CORS may not be needed
- If it is needed, make allowed origins configurable via env var

**Relative vs absolute API paths in frontend code**: `fetch("http://localhost:3001/api/users")`
- Change to relative: `fetch("/api/users")`
- Set up nginx proxy or platform basePath routing

**Environment-specific config files**: `.env.production`, `config.prod.json`
- Move to workload.yaml configurations or ReleaseBinding workloadOverrides

### Adaptation Checklist

For each service in the project:

1. **Identify all outbound URLs** - grep for `http://`, `localhost`, service names from docker-compose
2. **Replace with env vars + defaults** - keeps local dev working while OpenChoreo can inject real values
3. **Make the listen port configurable** - `const port = process.env.PORT || 3001`
4. **Move secrets to env vars** - never bake credentials into images
5. **For frontends**: switch to relative API paths + proxy pattern, or use build-time env vars
6. **Create workload.yaml** - declare endpoints, connections with envBindings matching the env var names you chose
7. **Verify locally** - the app should still work with default env var values

After changes, tell the user exactly what was modified and why, so they understand the pattern for future services.

## End-to-End Deployment Checklist

1. **Check CLI**: `occ version` (installed?)
2. **Configure API**: `occ config controlplane update default --url <URL>` then `occ login`
3. **Verify connection**: `occ namespace list`
4. **Set context**: `occ config context add myctx --controlplane default --credentials default --namespace <ns> --project <project>` then `occ config context use myctx`
5. **Discover only what you need**:
   - Project: `occ project list`
   - Environments/pipeline: `occ environment list`, `occ deploymentpipeline list`
   - Component types: `occ clustercomponenttype list`, `occ componenttype list`
   - Workflows for source builds: `occ workflow list`
6. **Scaffold**: `occ component scaffold my-app --type deployment/service -o my-app.yaml`
7. **Align project references**: set the target project in context, `spec.owner.projectName`, and `spec.workflow.parameters.scope.projectName`
8. **Configure source builds**: If building from source, add `spec.workflow` to the Component and add `workload.yaml` at the `appPath` root
9. **Adapt the app**: Replace hardcoded URLs and secrets with env vars plus local defaults
10. **Apply**: `occ apply -f my-app.yaml`
11. **Build** (if from source): `occ component workflow run my-app`, follow with `occ component workflow logs my-app -f`
12. **Verify**: `occ component get my-app`, `occ releasebinding list --project <proj> --component my-app`, `occ releasebinding get <binding>`, `occ component logs my-app`
13. **Promote**: `occ component deploy my-app --to staging`

## Debugging Deployments

All debugging goes through `occ`. Developers typically don't have kubectl access.

```bash
# 1. Check component status and conditions
occ component get my-app

# 2. Check workload
occ workload get my-app-workload

# 3. Check release bindings
occ releasebinding list --project my-proj --component my-app
occ releasebinding get <binding-name>

# 4. View application logs
occ component logs my-app --env dev --since 30m

# 5. View build logs
occ component workflow logs my-app -f

# 6. Check workflow runs
occ component workflowrun list my-app
```

Treat workflow logs, Component status, and ReleaseBinding status as the source of truth. `occ component workflowrun list my-app` can lag briefly after a build that already completed successfully.

Remember that `occ component workflow logs` does not accept `--project`; set or update context first when you switch projects.

Read the `status.conditions` section in `occ get` output. Common condition issues:

**ComponentType not found**: The referenced type doesn't exist. Check `occ clustercomponenttype list`.

**Build not running**: BuildPlane might not be configured. Escalate to PE.

**Rendering failed**: Usually a missing gateway or invalid parameter. Check the error message in conditions.

**Endpoint not accessible**: Verify the binding has a resolved URL. Check `occ releasebinding get <binding>` and inspect `status.endpoints`, `invokeURL`, `externalURLs`, and `internalURLs`. If no external URL is present, check endpoint visibility and gateway setup.

**Image pull errors**: Private registry needs imagePullSecrets in the ComponentType. Escalate to PE.

**Workload not created by build**: Check that `workload.yaml` exists at the `appPath` root with the correct name. Check build logs for descriptor-related errors.

**Dockerfile not found during source build**: Verify `docker.context` and `docker.filePath` are repo-root-relative paths to the real Docker build inputs. `appPath` does not rewrite those paths.

**Workload exists but Component says it is missing**: Compare `occ workload get <name>` against the Component's project. If `spec.owner.projectName` on the Workload is wrong, the source-build scope likely pointed at the wrong project. Fix the Component/workflow project refs, then regenerate or recreate the Workload; `spec.owner` is not safely patchable in place.

**Frontend loads but `/api/...` through the frontend returns 404**: Check whether the backend endpoint defines a `basePath` and the proxy upstream already includes it through a connection `address`. If so, switch the proxy to host/port bindings or remove the duplicated path.

**Frontend loads but browser requests fail with `localhost` or mixed-content behavior**: Check the built frontend env defaults. Prefer `/api` as the browser-facing default and avoid `||` fallbacks that can override intentional empty-string or same-origin configs.

If conditions show errors you can't resolve through occ, escalate to the platform engineering team with the exact error message.
