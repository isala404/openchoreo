# Troubleshooting

## Table of Contents

- [General Approach](#general-approach)
- [Control Plane Issues](#control-plane-issues)
- [Data Plane Issues](#data-plane-issues)
- [Build Plane Issues](#build-plane-issues)
- [Observability Plane Issues](#observability-plane-issues)
- [Connectivity Issues](#connectivity-issues)
- [Common Failure Patterns](#common-failure-patterns)

## General Approach

Start from the plane where the failure manifests, then work outward.

### Health check commands

```bash
# Plane pod status
kubectl get pods -n openchoreo-control-plane
kubectl get pods -n openchoreo-data-plane
kubectl get pods -n openchoreo-build-plane
kubectl get pods -n openchoreo-observability-plane

# Resource conditions (primary debugging tool)
occ <resource> get <name>
# Look at status.conditions for type, status, reason, message

# Cluster-wide resource view
kubectl get <crd> -A
```

### Log locations

| Component | Namespace | How to access |
|-----------|-----------|---------------|
| Controller Manager | `openchoreo-control-plane` | `kubectl logs deployment/controller-manager -n openchoreo-control-plane` |
| OpenChoreo API | `openchoreo-control-plane` | `kubectl logs deployment/openchoreo-api -n openchoreo-control-plane` |
| Backstage | `openchoreo-control-plane` | `kubectl logs deployment/backstage -n openchoreo-control-plane` |
| Cluster Gateway | `openchoreo-control-plane` | `kubectl logs deployment/cluster-gateway -n openchoreo-control-plane` |
| Data Plane Agent | `openchoreo-data-plane` | `kubectl logs deployment/cluster-agent -n openchoreo-data-plane` |
| Build Plane Agent | `openchoreo-build-plane` | `kubectl logs deployment/cluster-agent -n openchoreo-build-plane` |
| Observer | `openchoreo-observability-plane` | `kubectl logs deployment/observer -n openchoreo-observability-plane` |
| Fluent Bit | `openchoreo-observability-plane` | `kubectl logs -l app.kubernetes.io/name=fluent-bit -n openchoreo-observability-plane` |
| OpenSearch | `openchoreo-observability-plane` | `kubectl logs -l app=opensearch -n openchoreo-observability-plane` |

## Control Plane Issues

### Controller Manager not reconciling

```bash
kubectl logs deployment/controller-manager -n openchoreo-control-plane --tail=100
kubectl get events -n openchoreo-control-plane --sort-by='.lastTimestamp'
```

Common causes:
- RBAC permissions missing for a CRD (check for "forbidden" errors)
- Webhook certificate expired (check cert-manager)
- Resource validation failing (check admission webhook logs)

### OpenChoreo API errors

```bash
kubectl logs deployment/openchoreo-api -n openchoreo-control-plane --tail=100
```

Common causes:
- Database connectivity (SQLite file permissions or PostgreSQL connection)
- OIDC misconfiguration (issuer mismatch, JWKS unreachable)
- Authorization policy errors

### Backstage issues

```bash
kubectl logs deployment/backstage -n openchoreo-control-plane --tail=100
```

Common causes:
- OAuth callback URL mismatch
- Backend secret not configured
- Database migration failures

## Data Plane Issues

### Workloads not deploying

```bash
# Check the resource chain
occ component get <name>
occ releasebinding get <binding>

# Check data plane agent
kubectl logs deployment/cluster-agent -n openchoreo-data-plane --tail=50

# Check the actual workload on the data plane
kubectl get deployments -n <cell-namespace>
kubectl describe deployment <name> -n <cell-namespace>
kubectl get events -n <cell-namespace> --sort-by='.lastTimestamp'
```

Common causes:
- Agent disconnected from Control Plane
- ComponentType template rendering error (check conditions)
- Missing image pull secrets
- Resource quota exceeded
- Gateway not configured for the endpoint visibility level

### Endpoints not accessible

```bash
# Check release binding status for URLs
occ releasebinding get <binding>

# Check gateway resources
kubectl get gateway -A
kubectl get httproute -A
kubectl describe httproute <name> -n <ns>
```

Common causes:
- Northbound gateway not configured (for external endpoints)
- Westbound gateway not configured (for internal/namespace endpoints)
- TLS certificate not provisioned
- DNS not pointing to LoadBalancer

## Build Plane Issues

### Builds not starting

```bash
# Check build plane agent connectivity
kubectl logs deployment/cluster-agent -n openchoreo-build-plane --tail=50

# Check Argo Workflows controller
kubectl get pods -n openchoreo-build-plane
kubectl logs deployment/argo-workflows-workflow-controller -n openchoreo-build-plane --tail=50

# Check WorkflowRun status
occ component workflowrun list <component>
kubectl get workflows.argoproj.io -n openchoreo-build-plane
```

Common causes:
- BuildPlane CR not registered in Control Plane
- Agent disconnected
- Argo Workflows controller not running
- ClusterWorkflowTemplate missing

### Build failures

```bash
# Follow build logs
occ component workflow logs <component> -f

# Check Argo workflow pods
kubectl get pods -n openchoreo-build-plane -l workflows.argoproj.io/workflow
kubectl logs <workflow-pod> -n openchoreo-build-plane -c main

# Check specific step
kubectl logs <workflow-pod> -n openchoreo-build-plane -c <step-name>
```

Common causes:
- Registry push credentials invalid or missing
- Dockerfile not found (wrong `docker.context` or `docker.filePath`)
- `generate-workload-cr` step failing (missing `workload.yaml` at `appPath` root)
- Source repo access denied (missing `secretRef`)

## Observability Plane Issues

### Logs not appearing

```bash
# Check Fluent Bit
kubectl get pods -n openchoreo-observability-plane -l app.kubernetes.io/name=fluent-bit
kubectl logs -l app.kubernetes.io/name=fluent-bit -n openchoreo-observability-plane --tail=50

# Check OpenSearch
kubectl get pods -n openchoreo-observability-plane -l app=opensearch
kubectl logs -l app=opensearch -n openchoreo-observability-plane --tail=50

# Check Observer API
kubectl logs deployment/observer -n openchoreo-observability-plane --tail=50
```

Common causes:
- Fluent Bit output misconfigured (wrong OpenSearch endpoint)
- OpenSearch cluster not ready (storage issues, resource limits)
- ObservabilityPlane CR not registered
- In multi-cluster: agent disconnected or telemetry export config wrong

### Metrics not available

```bash
kubectl get pods -n openchoreo-observability-plane -l app.kubernetes.io/name=prometheus
kubectl get servicemonitors --all-namespaces
```

### Traces not arriving

```bash
kubectl get pods -n openchoreo-observability-plane -l app.kubernetes.io/name=opentelemetry-collector
kubectl logs -l app.kubernetes.io/name=opentelemetry-collector -n openchoreo-observability-plane --tail=50
```

### Alerts not triggering

```bash
kubectl get observabilityalertrules -n <namespace>
kubectl describe observabilityalertrule <name> -n <namespace>
kubectl logs deployment/observer -n openchoreo-observability-plane --tail=50
```

## Connectivity Issues

### Agent not connecting to Control Plane

```bash
# On remote cluster
kubectl logs deployment/cluster-agent -n <agent-namespace> --tail=50

# On control plane
kubectl logs deployment/cluster-gateway -n openchoreo-control-plane --tail=50
```

Checklist:
1. Is the Cluster Gateway reachable from the remote cluster? (network/firewall)
2. Do the certificate SANs match the connection URL?
3. Is the CA ConfigMap present in the agent namespace?
4. Has the agent's client CA been embedded in the plane CR?
5. Has cert-manager issued the certificates? `kubectl get certificate -A`

### Certificate issues

```bash
# Check cert-manager
kubectl get certificate -A
kubectl describe certificate <name> -n <ns>
kubectl logs deployment/cert-manager -n cert-manager --tail=50

# Check if secrets exist
kubectl get secret cluster-gateway-ca -n openchoreo-control-plane
kubectl get secret cluster-agent-tls -n <agent-namespace>
```

## Common Failure Patterns

### Resources stuck in "Pending"

1. Check if the target plane agent is connected
2. Check controller-manager logs for reconciliation errors
3. Check if the namespace has the `openchoreo.dev/controlplane-namespace=true` label

### "forbidden" errors in controller logs

Missing RBAC for a CRD. The agent service accounts are:
- Data Plane: `cluster-agent-dataplane` in `openchoreo-data-plane`
- Build Plane: `cluster-agent-buildplane` in `openchoreo-build-plane`
- Observability Plane: `cluster-agent-observabilityplane` in `openchoreo-observability-plane`

### Webhook validation failures

When a ComponentType, Trait, or Component fails to apply:

```bash
# Check webhook logs
kubectl logs deployment/controller-manager -n openchoreo-control-plane --tail=50 | grep -i webhook

# Check if webhook is registered
kubectl get validatingwebhookconfigurations | grep openchoreo
```

Common causes: invalid CEL expressions in templates, schema syntax errors, references to non-existent traits or workflows.

### Cluster agent RBAC for third-party CRDs

When using CRDs not shipped with OpenChoreo (Istio, Knative, cert-manager, Prometheus Operator), the agent needs additional permissions:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: openchoreo-custom-resources
rules:
  - apiGroups: ["monitoring.coreos.com"]
    resources: ["servicemonitors"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: openchoreo-custom-resources-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: openchoreo-custom-resources
subjects:
  - kind: ServiceAccount
    name: cluster-agent-dataplane
    namespace: openchoreo-data-plane
```
