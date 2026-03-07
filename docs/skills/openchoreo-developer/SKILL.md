---
name: openchoreo-developer
description: |
  Deploying, managing, debugging, and explaining applications and resources on OpenChoreo (open-source IDP on Kubernetes). Use this whenever the user mentions OpenChoreo, occ CLI, workload.yaml, Project/Component/Workload/ReleaseBinding/WorkflowRun, ComponentType, Trait, SecretReference, deployment pipelines, or wants to deploy or debug an app on OpenChoreo, even if they only mention YAML, logs, builds, or routing problems.
---

# OpenChoreo Developer Guide

Help developers work with OpenChoreo, an open-source Internal Developer Platform on Kubernetes. Default assumption: developers have `occ` access but NOT `kubectl` access.

## Reference files

Read `references/` files as needed, not all at once:

- **`concepts.md`** - OpenChoreo abstractions, resource relationships, cell architecture. Read when explaining concepts or understanding how things fit together.
- **`cli-reference.md`** - Install occ, setup, all commands, exploration workflow. Read when running CLI commands or first-time setup.
- **`deployment-guide.md`** - End-to-end deployment, workload descriptors, source builds, promoting, debugging. Read when deploying an app.
- **`resource-schemas.md`** - Full YAML schemas for all resources. Read when writing or debugging YAML.
- **`platform-engineer.md`** - Platform-side abstractions (ComponentType, Trait, Workflow definitions, infrastructure planes). Read when you need to understand what the platform provides or when something requires PE escalation.

Before inventing YAML, prefer repo-backed examples from `samples/from-image/`, `samples/from-source/`, and `samples/getting-started/`.

## Start from these OpenChoreo truths

Treat these as known defaults unless live cluster output disproves them:

- Developers usually work entirely through `occ`, not `kubectl`.
- `occ component scaffold` takes the component name as a positional argument: `occ component scaffold my-app --type deployment/service`.
- `occ <resource> get <name>` returns the full YAML. Do not look for `-o` / `--output`.
- For source builds, the current Component shape is `spec.workflow`, not old `spec.build` or `templateRef` examples from older docs or proposals.
- `workload.yaml` belongs at the root of the workflow `appPath`.
- For Docker source builds, `repository.appPath` and `docker.context` / `docker.filePath` solve different problems:
  - `appPath` tells the workflow which source subdirectory and `workload.yaml` to use.
  - `docker.context` and `docker.filePath` must still point at the real repo-root-relative Docker build paths.
  - Example: if the repo uses `backend/Dockerfile` and `appPath: ./backend`, then use `docker.context: ./backend` and `docker.filePath: ./backend/Dockerfile` or the equivalent leading-slash form.
- For source builds, keep the target project aligned in all places:
  - active `occ` context project
  - `spec.owner.projectName`
  - `spec.workflow.parameters.scope.projectName`
  If any of these still says `default`, the build can generate Workloads owned by the wrong project.
- A frontend with a custom Dockerfile, nginx proxy, or nonstandard build/runtime should usually use the `docker` workflow even if the app is written in React. Reserve a framework-specific workflow such as `react` for the simple/default shape it expects.
- `occ component workflow run` accepts `--project`, but `occ component workflow logs` does not. Set or update context before log-following and later `get`/debug steps instead of assuming subcommand flags are consistent.
- Workload `spec.owner` is effectively immutable once created. If a build generated a Workload under the wrong project, fix the Component/workflow project references and rerun or recreate the Workload; do not plan on patching the owner in place.
- For frontend reverse proxies, do not blindly use a connection `address` env var behind a `/api/` location when the backend endpoint already has a `basePath`; that can create `/api/api/...` requests. Prefer `host` and `port` bindings, or handle `basePath` separately.
- For browser bundles, prefer relative `/api` defaults. If a build-time env may be intentionally empty or omitted, read it with `??` or an explicit `undefined` check rather than `||`, which can accidentally fall back to `http://localhost`.
- Actual deployed URLs come from `occ releasebinding get <binding>` status fields such as `invokeURL`, `externalURLs`, and `internalURLs`. Never construct them by hand.
- `occ component workflow logs <name> -f` plus `occ component get` / `occ releasebinding get` are better truth sources than immediately trusting `occ component workflowrun list <name>`, which can lag behind a completed build.

## Route by task

### Explaining concepts

- Read `references/concepts.md` first.
- Read `references/platform-engineer.md` only if the question crosses into ComponentType internals, Trait definitions, workflow templates, gateways, or PE-managed planes.
- Explain concepts with practical examples tied to Projects, Components, Workloads, ReleaseBindings, and Workflows instead of repeating abstract documentation.

### Debugging an existing app or deployment

Start with the specific component or binding the user already has. Do NOT run a full cluster inventory unless names are unknown or the failure points there.

1. **Inspect the current state first**:
   - `occ component get <name>`
   - `occ releasebinding list --project <proj> --component <comp>`
   - `occ releasebinding get <binding>`
   - `occ component logs <name> --env <env> --since 30m`
   - `occ component workflow logs <name> -f`
   - `occ component workflowrun list <name>`

2. **Broaden only if the failure points there**:
   - Missing type -> `occ clustercomponenttype list`, `occ componenttype list`
   - Missing workflow -> `occ workflow list`
   - Missing trait -> `occ clustertrait list`, `occ trait list`
   - Unknown env/pipeline -> `occ environment list`, `occ deploymentpipeline list`

3. **Never guess endpoint URLs**:
   - Inspect `status.endpoints`, `invokeURL`, `externalURLs`, or `internalURLs` in `occ releasebinding get <binding>`.
   - If no external URL appears, check endpoint visibility and gateway setup before assuming the route format.

### Deploying a new app

When a user says "deploy this to OpenChoreo":

1. **Analyze the app**: Read Dockerfile(s), compose files, package manifests, env handling, ports, and inter-service dependencies.

2. **Ensure occ is installed**: Run `occ version`. If missing, read `references/cli-reference.md` for install steps. Download to `/tmp`, not the working directory.

3. **Ask for the API URL if not configured**: Run `occ namespace list`. If it fails, ask the user: "What's your OpenChoreo API server URL?" Then configure: `occ config controlplane update default --url <their-url>` and `occ login`.

4. **Set or update context once namespace/project are known** so later commands do not repeat flags:
   ```
   occ config context add myctx --controlplane default --credentials default \
     --namespace <ns> --project <project>
   occ config context use myctx
   ```
   - If the project is created later, immediately run `occ config context update <ctx> --project <project>` before scaffolding, building, or reading workflow logs.

5. **Discover only what this task needs**:
   - Need a project name? `occ project list`
   - Need environments or promotion path? `occ environment list`, `occ deploymentpipeline list`
   - Need a ComponentType? `occ clustercomponenttype list`, `occ componenttype list`
   - Need traits? `occ clustertrait list`, `occ trait list`
   - Need a source-build workflow? `occ workflow list`

6. **If the component already exists, inspect it before scaffolding** with `occ component get <name>`.

7. **Map services to components**: Each service becomes a Component. Pick the ComponentType from what's actually available on the cluster. Common mappings:
   - Backend API: `deployment/service`
   - Web frontend: `deployment/web-application`
   - Scheduled job: `cronjob/<available-type>`

8. **Scaffold instead of hand-writing the first draft**:
   - `occ component scaffold <name> --type <workloadType/typeName> -o <file>`
   - Add traits or workflow only when the chosen type actually supports them.

9. **For source builds, use `spec.workflow`, not the obsolete `spec.build` shape**:
   - Choose a workflow from `occ workflow list`
   - Inspect it with `occ workflow get <name>` if you need its parameter schema
   - If the repo has a custom Dockerfile or custom web server/proxy setup, default to the `docker` workflow instead of assuming a framework-specific workflow fits
   - Keep `spec.owner.projectName` and `spec.workflow.parameters.scope.projectName` identical to the target project before the first build
   - Create a `workload.yaml` descriptor in each service's `appPath` root so the build can generate the Workload CR with endpoints and connections
   - Keep `docker.context` and `docker.filePath` aligned to the real repo layout, not just the `appPath`
   - Read `references/deployment-guide.md` for descriptor format and examples

10. **For inter-service communication**: Use Workload connections, not hardcoded URLs. The platform resolves service addresses and injects them as env vars. If services need to talk to each other, use the `connections` field in the workload descriptor.
   - For nginx or similar reverse proxies, prefer `host` / `port` bindings unless you explicitly want the endpoint `basePath` folded into the upstream URL.

11. **Adapt the code for OpenChoreo**: Scan the project for things that will not work on OpenChoreo and propose changes that keep local dev working too. Read `references/deployment-guide.md` "Making Local Apps Work on OpenChoreo" section. Key things to find and fix:
   - Hardcoded `localhost` / `127.0.0.1` URLs -> replace with env var reads, keeping localhost as the default
   - Docker-compose service names used as hostnames -> replace with env vars, use connections on OpenChoreo
   - Hardcoded secrets -> move to env vars, use SecretReference on OpenChoreo
   - Frontend absolute API URLs -> switch to relative paths with proxy or build-time env vars
   - Explain the compatibility changes before editing application code when they change runtime behavior.

12. **Apply and verify**:
   - `occ apply -f <file>`
   - Source build: `occ component workflow run <name>` then `occ component workflow logs <name> -f`
   - Before `workflow logs`, make sure context already points at the right project because that subcommand does not accept `--project`
   - Verify with `occ component get <name>`, `occ releasebinding list --project <proj> --component <comp>`, `occ releasebinding get <binding>`, and `occ component logs <name>`
   - For frontends, verify both the shell page and at least one proxied API request through the frontend URL, not just the backend URL directly

### Writing or fixing YAML

- Read `references/resource-schemas.md` and the nearest matching sample before editing.
- Prefer `occ component scaffold` for Components and real samples for Workload, ReleaseBinding, and SecretReference shapes.
- For source builds:
  - Component uses `spec.workflow`
  - Source repo uses `workload.yaml`
- For BYOI:
  - You typically manage Component + Workload directly.

## Key rules

**No kubectl**: Developers typically don't have cluster access. Everything goes through `occ`. If debugging requires kubectl, frame it as a PE escalation.

**occ get returns YAML**: `occ <resource> get <name>` outputs full YAML (spec + status). No `--output`/`-o` flag. This is the primary debugging tool.

**Use scaffold**: `occ component scaffold <name> ...` generates correct YAML from the cluster's actual types. Always prefer it over writing YAML from scratch.

**`deploymentPipelineRef` is a string**: Just the pipeline name, not an object. `deploymentPipelineRef: default`, not `deploymentPipelineRef: {kind: ..., name: ...}`.

**Source builds use `workflow`**: On Component resources, use `spec.workflow`. Do not use old `spec.build` or `templateRef` examples.

**Workload descriptor placement**: `workload.yaml` goes at the root of the `appPath` directory (not the docker context, not the repo root). If `appPath` is `/backend`, the file goes at `/backend/workload.yaml` in the repo.

**Docker workflow paths are repo-relative**: `appPath` does not make `docker.context` or `docker.filePath` relative to that folder. Point them at the actual repo paths for the Docker build.

**Project references must agree**: For source builds, align the active context project, `spec.owner.projectName`, and `spec.workflow.parameters.scope.projectName` before the first build. Do not leave scaffolded `default` values in place when deploying to another project.

**Workflow subcommands are not flag-consistent**: `occ component workflow run` accepts `--project`; `occ component workflow logs` does not. Use context to carry project scope for follow-up log and debug commands.

**Endpoint visibility and gateways**: `external` requires a northbound gateway (usually set up). `internal` and `namespace` require a westbound gateway which may not be configured. If `internal` visibility causes rendering errors, it likely means the internal gateway isn't set up. Escalate to PE or use `external` only.

**autoDeploy**: Set `spec.autoDeploy: true` on Component to auto-create releases when Workload changes. Otherwise you need to manually run `occ component deploy`.

**Use ReleaseBinding status for deployed URLs**: When you need the actual invoke URL, inspect `occ releasebinding get <binding>` instead of constructing hostnames by hand.

**Workflow run listings can lag**: If `workflowrun list` still shows `Pending` but the workflow logs show a successful publish/generate/deploy path, confirm through `occ component get` and `occ releasebinding get` before assuming the build is still stuck.

**Workload owners are immutable in practice**: If a generated Workload points at the wrong project/component owner, fix the source build config and recreate or regenerate the Workload instead of trying to patch `spec.owner`.

**Proxy path handling matters**: If a connection `address` already includes an endpoint `basePath`, do not prepend the same path again in nginx or app routing.

**Frontend browser builds should default to same-origin paths**: Prefer `/api` over `http://localhost...` for production-safe defaults, and use `??` or explicit undefined checks when empty-string env values are meaningful.

## PE escalation

Some things are outside what a developer can do. When you hit these, generate a clear message for the user to send to their platform engineering team:

**Format**: "To do X, we need Y configured on the platform side. Can you ask the platform engineering team to Z?"

**Common escalations** (read `references/platform-engineer.md` for details):
- **Missing ComponentType**: "We need a ComponentType for [use case]. Can you ask the PE team to create a `deployment/<name>` ComponentType with [requirements]?"
- **Missing Trait**: "We need a [capability] trait. Can you ask the PE team to create a Trait that [does X]?"
- **Internal gateway not configured**: "Inter-service communication across projects requires an internal gateway. Can you ask the PE team to configure the westbound gateway on the DataPlane?"
- **Private registry access**: "Pulling from a private registry needs imagePullSecrets configured in the ComponentType. Can you ask the PE team to add registry credentials?"
- **Secret store setup**: "Storing secrets requires a ClusterSecretStore configured on the DataPlane. Can you ask the PE team to set one up?"
- **New environment**: "We need a [staging/production] environment. Can you ask the PE team to create an Environment resource pointing to the right DataPlane?"
- **Build plane issues**: "Builds aren't running, which usually means the BuildPlane isn't configured or connected. Can you ask the PE team to check the BuildPlane status?"

## Debugging

1. Check resource status: `occ <resource> get <name>` and read the `conditions` section
2. Check app logs: `occ component logs <name> --env <env> --since 30m`
3. Check build logs: `occ component workflow logs <name> -f`
4. Check release binding: `occ releasebinding list --project <proj> --component <comp>` then `occ releasebinding get <name>`
5. If conditions show errors you can't resolve through occ, escalate to PE with the exact error message

## Explaining concepts

When users ask about a concept, read `references/concepts.md` and explain with practical examples. For platform-side concepts (ComponentType internals, Trait definitions, CEL templates), also read `references/platform-engineer.md`. Connect abstractions to real scenarios rather than repeating documentation language.

## Anti-patterns

- Running every discovery command when a focused inspect flow already has the answer
- Using obsolete `spec.build`, `templateRef`, or other stale YAML from older docs
- Writing YAML from scratch instead of using `occ component scaffold`
- Using `occ component scaffold --name ...`; the component name is positional
- Leaving scaffolded `default` project values in `spec.owner.projectName` or `spec.workflow.parameters.scope.projectName` when deploying to another project
- Putting environment-specific config in Component instead of ReleaseBinding envOverrides
- One giant component for a multi-service app instead of separate components per service
- Hardcoding secrets in env vars instead of using SecretReference
- Hardcoding inter-service URLs instead of using Workload connections
- Using `internal` endpoint visibility without verifying the internal gateway exists
- Placing `workload.yaml` in the wrong directory (must be at `appPath` root)
- Assuming `appPath` also rewrites Docker build paths
- Assuming every `occ component workflow ...` subcommand accepts `--project`
- Trying to patch `Workload.spec.owner` after a build produced the wrong owner
- Modifying code so it only works on OpenChoreo but breaks local dev (always use env vars with local defaults)
- Hardcoding service URLs in frontend code instead of using relative paths with a proxy
- Using connection `address` behind an `/api/` proxy without checking whether the backend endpoint already contributes `/api`
- Using `||` for browser build-time API envs when empty-string or omitted values should preserve same-origin behavior
- Guessing endpoint URLs instead of checking ReleaseBinding status
