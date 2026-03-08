---
name: openchoreo-developer
description: |
  Use this whenever the task is about working with an application on OpenChoreo: deploying, updating, debugging, explaining resources, writing app-facing YAML, or using `occ`. If the task also needs kubectl access, platform resources, cluster-side debugging, or platform configuration changes, activate `openchoreo-platform-engineer` too instead of treating it as a later escalation.
---

# OpenChoreo Developer Guide

Help with application-level work on OpenChoreo. Keep this file lean, discover the current platform shape from `occ`, and read detailed references only when the task actually needs them.

## Scope and pairing

Use this skill for developer-owned work:

- Deploying a new app or service to OpenChoreo
- Debugging an existing Component, Workload, ReleaseBinding, or WorkflowRun
- Explaining OpenChoreo app concepts and resource relationships
- Writing or fixing app-facing YAML
- Adapting an application so it runs cleanly on OpenChoreo

Activate `openchoreo-platform-engineer` at the same time when the task also includes any of these:

- `kubectl` investigation
- platform resources such as DataPlane, BuildPlane, Environment, DeploymentPipeline, ComponentType, Trait, or Workflow authoring
- gateway, secret store, registry, identity, or other platform configuration
- a likely PE-side failure rather than an app-level configuration problem

If both skills are available and the task involves both deployment/debugging and platform behavior, use both immediately. Many OpenChoreo problems cross that boundary.

## Working style

Prefer progressive discovery:

1. Understand the application shape from the repo before editing YAML.
2. Check `occ` access, context, and the live resources already involved.
3. Discover only the cluster resources needed for this task.
4. Read the matching reference file only after you know which area is relevant.
5. Apply the smallest viable change and verify through live status and logs.

The current cluster output is more trustworthy than memory. Do not assume available ComponentTypes, Traits, Workflows, environments, or field names. Discover them from `occ` first.

Before inventing YAML, prefer live scaffolding and repository samples.

## Reference routing

Read only the relevant reference file:

- `references/concepts.md` for resource relationships and OpenChoreo concepts
- `references/cli-reference.md` for `occ` install, setup, command behavior, and CLI gotchas
- `references/deployment-guide.md` for BYOI, source builds, `workload.yaml`, connections, overrides, and deployment flow
- `references/resource-schemas.md` for exact app-facing YAML shapes
- `references/platform-engineer.md` when the task crosses into PE-managed capabilities or needs a clean escalation path

Also prefer repo-backed examples from `samples/from-image/`, `samples/from-source/`, and `samples/getting-started/` before writing a first draft by hand.

## Discovery-first workflow

### 1. Inspect the repo and classify the app

Start by understanding what is being deployed:

- Services and runtimes
- Dockerfiles and build system
- ports, env vars, and inter-service dependencies
- whether the app fits a simple image-based path or a source-build path

Do not scaffold or patch resources until the application shape is clear.

### 2. Check `occ` access and current context

Confirm the basics early:

- `occ version`
- current control plane and login status
- namespace and project context

If connectivity or auth is missing, fix that before reasoning about app resources.

### 3. Discover only what this task needs

Use focused discovery instead of broad inventory:

- existing project, component, or release binding when names are known
- available ComponentTypes only if you need to scaffold or change the type
- available Workflows only if this is a source build
- environments and deployment pipelines only if deployment or promotion depends on them

If the component already exists, inspect it before scaffolding or rewriting it.

### 4. Prefer generated or observed shapes over guessed YAML

Use `occ component scaffold` for Components whenever possible. For existing resources, inspect the current YAML before editing.

If a field path matters, confirm it in the live resource, schema reference, or current docs before patching. This avoids stale assumptions around workflow config, overrides, and app-to-platform boundaries.

### 5. Verify with live app evidence

Use OpenChoreo resources to verify:

- `occ component get`
- `occ releasebinding get`
- `occ component logs`
- `occ component workflow logs`

Trust deployed URLs and endpoint details from ReleaseBinding status instead of constructing them by hand.

## Stable guardrails

Keep these because they are durable and routinely useful:

- Default to `occ`; if the task needs `kubectl`, that is usually a PE boundary or a mixed-skill task
- `occ <resource> get <name>` returns full YAML and is a primary debugging tool
- Prefer scaffolding and samples over hand-written first drafts
- Source-build Components use `spec.workflow`; `workload.yaml` belongs at the root of the selected `appPath`
- Use ReleaseBinding status for the actual deployed URLs
- When platform capabilities are missing or broken, escalate clearly or activate `openchoreo-platform-engineer`

## Escalation rule

When you hit a PE-owned issue, state it directly and make the ask concrete:

"To do X, we need Y configured on the platform side. Please ask the platform engineering team to Z."

Route to `references/platform-engineer.md` before writing that escalation so it names the missing platform capability correctly.

## Anti-patterns

- Running every discovery command before checking the resource already implicated
- Writing Components or overrides from memory when `occ` can scaffold or reveal the current shape
- Reusing old examples without checking the current workflow and schema model
- Guessing deployed URLs or route formats instead of reading ReleaseBinding status
- Treating a platform-side failure as an app-only problem after `occ` evidence points elsewhere
