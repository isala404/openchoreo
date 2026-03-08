# OCC CLI Reference

The `occ` CLI manages OpenChoreo resources. Config lives at `~/.occ/config.yaml`.

## Install

Download to `/tmp` to keep the working directory clean:

```bash
# macOS Apple Silicon
curl -L https://nightly.link/openchoreo/openchoreo/workflows/build-and-test/main/occ.zip -o /tmp/occ.zip
unzip /tmp/occ.zip -d /tmp/occ-bin
chmod +x /tmp/occ-bin/darwin/arm64/occ
sudo mv /tmp/occ-bin/darwin/arm64/occ /usr/local/bin/
rm -rf /tmp/occ.zip /tmp/occ-bin

# For releases: download from github.com/openchoreo/openchoreo/releases
# curl -L <release-url> -o /tmp/occ.tar.gz
# tar -xzf /tmp/occ.tar.gz -C /tmp/occ-bin && chmod +x /tmp/occ-bin/occ && sudo mv /tmp/occ-bin/occ /usr/local/bin/
```

Platforms: `darwin/amd64`, `darwin/arm64`, `linux/amd64`, `linux/arm64`

Verify: `occ version`

## Setup Flow

After installing, the CLI needs to know where the OpenChoreo API server is. Ask the user for this URL if you don't know it. Never assume localhost.

```bash
# 1. Configure control plane endpoint (ask user for the URL)
occ config controlplane update default --url <API_SERVER_URL>

# 2. Login (opens browser for PKCE auth)
occ login

# 3. Verify connection
occ namespace list

# 4. Create context with defaults (optional but recommended)
occ config context add myctx --controlplane default --credentials default \
  --namespace default --project my-project

# 5. Use context
occ config context use myctx
```

Service account login: `occ login --client-credentials --client-id <id> --client-secret <secret>`

## Config Modes

- **api-server** (default): Talks to remote OpenChoreo API server
- **file-system**: Works with local YAML files for GitOps workflows

## Global Flags

Do not assume flag support is uniform across `occ` subcommands. In practice:

- many `list` commands accept scope flags such as `--project`
- many `get` commands use `--namespace` and do not accept `--project`
- `occ component workflow logs` accepts `--namespace` but not `--project`

Use `--help` on the exact subcommand when scope handling matters. Context defaults often carry project selection more reliably than flags.

## Important: occ get returns YAML

Unlike kubectl, occ has no `--output` / `-o` flag. `occ <resource> get <name>` always returns the full YAML (spec + status). This is the primary way to inspect and debug resources.

## Commands Quick Reference

| Command | Aliases | Actions |
|---------|---------|---------|
| `namespace` | `ns` | list, get, delete |
| `project` | `proj` | list, get, delete |
| `component` | `comp` | list, get, delete, scaffold, deploy, logs, workflow run/logs, workflowrun list/logs |
| `environment` | `env` | list, get, delete |
| `dataplane` | `dp` | list, get, delete |
| `buildplane` | `bp` | list, get, delete |
| `observabilityplane` | `op` | list, get, delete |
| `deploymentpipeline` | `deppipe` | list, get, delete |
| `componenttype` | `ct` | list, get, delete |
| `clustercomponenttype` | `cct` | list, get, delete |
| `trait` | `traits` | list, get, delete |
| `clustertrait` | `clustertraits` | list, get, delete |
| `workflow` | `wf` | list, get, run, logs |
| `workflowrun` | `wr` | list, get, logs |
| `secretreference` | `sr` | list, get, delete |
| `workload` | `wl` | create, list, get, delete |
| `componentrelease` | - | generate (fs-mode), list, get |
| `releasebinding` | - | generate (fs-mode), list, get, delete |
| `authzclusterrole` | `cr` | list, get, delete |
| `authzclusterrolebinding` | `crb` | list, get, delete |
| `authzrole` | - | list, get, delete |
| `authzrolebinding` | `rb` | list, get, delete |

## Key Commands in Detail

### apply
```bash
occ apply -f <file.yaml>    # Create/update resources from YAML
```

### component scaffold
Generates Component YAML from available ComponentTypes and Traits. Always prefer this over writing YAML from scratch.

```bash
# --type format is workloadType/typeName (e.g., deployment/service)
occ component scaffold my-app --type deployment/service
occ component scaffold my-app --type deployment/web-application --traits storage,ingress
occ component scaffold my-app --type deployment/web-application --workflow react
occ component scaffold my-app --type deployment/web-application -o my-app.yaml
occ component scaffold my-app --type deployment/web-application --skip-comments --skip-optional
```

### component deploy
```bash
occ component deploy my-app                           # Deploy latest release to root env
occ component deploy my-app --to staging              # Promote to staging
occ component deploy my-app --release my-app-20260126-143022-1  # Deploy specific release
occ component deploy my-app --set spec.componentTypeEnvOverrides.replicas=3
```

### component logs
```bash
occ component logs my-app                    # Logs from lowest environment
occ component logs my-app --env production   # Specific environment
occ component logs my-app --env dev -f       # Follow logs
occ component logs my-app --since 30m        # Last 30 minutes
```

### workflow
```bash
occ component workflow run my-app             # Trigger build
occ component workflow logs my-app -f         # Follow build logs
occ component workflowrun list my-app         # List builds
occ workflow run migration --set spec.workflow.parameters.key=value
```

### workload create
```bash
occ workload create --name my-wl --component my-app --image nginx:latest
occ workload create --name my-wl --component my-app --descriptor workload.yaml
occ workload create --name my-wl --component my-app --descriptor workload.yaml --dry-run
```

### componentrelease / releasebinding (file-system mode only)
```bash
occ componentrelease generate --all
occ componentrelease generate --project my-proj --component my-comp
occ releasebinding generate --target-env development --use-pipeline default --all
```

## Debugging with occ get

`occ <resource> get <name>` returns YAML output showing the full resource spec and status including conditions. This is your primary debugging tool.

```bash
occ component get my-app             # See component spec, type ref, status conditions
occ workload get my-workload         # See container image, ports, connections
occ environment get dev              # See dataplane mapping, status
occ componenttype get web-app        # See schema, templates, allowed workflows
occ trait get ingress                 # See trait schema, creates, patches
occ releasebinding get my-binding    # See env overrides, deployment status
occ deploymentpipeline get default   # See environment progression paths
```

Look at `status.conditions` in the output. Each condition has `type`, `status`, `reason`, and `message` fields that explain what's happening.

## Exploration Workflow

When working with an unfamiliar OpenChoreo cluster, explore in this order:

```bash
occ namespace list                   # What namespaces exist?
occ config context update myctx --namespace <ns>

occ project list                     # What projects exist?
occ environment list                 # What environments are available?
occ deploymentpipeline list          # What promotion paths exist?

occ clustercomponenttype list        # What component types are available cluster-wide?
occ componenttype list               # What types are available in this namespace?
occ clustertrait list                # What traits are available cluster-wide?
occ trait list                       # What traits are in this namespace?
occ workflow list                    # What build workflows exist?

occ component list --project my-proj # What components are deployed?
occ workload list                    # What workloads exist?
```

## Common Gotchas

**scaffold --type format**: Must be `workloadType/typeName`, not just the type name.
- Wrong: `occ component scaffold --type service`
- Right: `occ component scaffold --type deployment/service`

**scaffold component name is positional**: There is no `--name` flag on `occ component scaffold`.
- Wrong: `occ component scaffold --name my-app --type deployment/service`
- Right: `occ component scaffold my-app --type deployment/service`

**component get has no --project flag**: The `get` subcommand only takes `--namespace`. Scoping works through context defaults.
- Wrong: `occ component get my-app --project default`
- Right: `occ component get my-app` (with project set in context or globally)

**deploymentPipelineRef is a string**: In Project YAML, use `deploymentPipelineRef: default`, not `deploymentPipelineRef: { kind: ..., name: ... }`.

**Docker workflow paths are repo-relative**: `repository.appPath` selects the source subdirectory and `workload.yaml`, but `docker.context` and `docker.filePath` must still point at real repo-root-relative paths. If `appPath` is `./backend`, a Dockerfile under `backend/` should use `docker.context: ./backend` and `docker.filePath: ./backend/Dockerfile`.

**Source-build project scope must match in multiple places**: Keep the active context project, `spec.owner.projectName`, and `spec.workflow.parameters.scope.projectName` aligned before the first build. A mismatched workflow scope can generate Workloads in the wrong project.

**No --output/-o flag**: Unlike kubectl, `occ get` always returns YAML. There's no JSON or table output option.

**list vs get scope**: `list` commands respect `--project` flag. `get` commands work with `--namespace` only.

**workflowrun list can lag**: A just-finished build may still appear `Pending` briefly. Confirm completion with `occ component workflow logs`, `occ component get`, and `occ releasebinding get`.

**workflow subcommands are inconsistent about `--project`**:
- `occ component workflow run` accepts `--project`
- `occ component workflow logs` does not
- After changing projects, update or switch context before using `workflow logs`, `component get`, or similar follow-up commands

**releasebinding list requires `--component`**:
- Wrong: `occ releasebinding list --project my-proj`
- Right: `occ releasebinding list --project my-proj --component my-app`

**Workload owners are not patch-friendly**: If a generated Workload has the wrong `spec.owner`, plan to regenerate or recreate it after fixing the Component/workflow project config rather than editing the owner in place.
