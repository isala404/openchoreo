# Operations

## Table of Contents

- [Namespace Provisioning](#namespace-provisioning)
- [Deployment Topology](#deployment-topology)
- [Multi-Cluster Connectivity](#multi-cluster-connectivity)
- [Upgrades](#upgrades)

## Namespace Provisioning

Every controlplane namespace needs a minimum set of resources before developers can use it.

### Create and label the namespace

```bash
export NAMESPACE_NAME="<your-namespace>"
kubectl create namespace $NAMESPACE_NAME
kubectl label namespace $NAMESPACE_NAME openchoreo.dev/controlplane-namespace=true
```

The label is what tells controllers to reconcile resources in this namespace.

### Register a DataPlane

Extract the agent CA from the data plane cluster and create a DataPlane CR:

```bash
export DATAPLANE_NAME="<your-dataplane>"
DP_CA_CERT=$(kubectl --context ${DATA_PLANE_CONTEXT} get secret cluster-agent-tls \
  -n openchoreo-data-plane \
  -o jsonpath='{.data.ca\.crt}' | base64 -d)

kubectl apply -f - <<EOF
apiVersion: openchoreo.dev/v1alpha1
kind: DataPlane
metadata:
  name: $DATAPLANE_NAME
  namespace: $NAMESPACE_NAME
  annotations:
    openchoreo.dev/display-name: "$DATAPLANE_NAME"
spec:
  planeID: default
  secretStoreRef:
    name: default
  gateway:
    ingress:
      external:
        name: gateway-default
        namespace: openchoreo-data-plane
        http:
          host: openchoreoapis.localhost
          port: 19080
          listenerName: http
  clusterAgent:
    clientCA:
      value: |
$(echo "$DP_CA_CERT" | sed 's/^/        /')
EOF
```

For single-cluster setups, the agent CA comes from the same cluster. For multi-cluster, see [Multi-Cluster Connectivity](#multi-cluster-connectivity).

### Copy default ComponentTypes and Workflows

```bash
# ComponentTypes (strip cluster metadata before applying to new namespace)
for ct in service web-application scheduled-task worker; do
  kubectl get componenttype $ct -o yaml | \
    yq eval "del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .status) | .metadata.namespace = \"$NAMESPACE_NAME\"" - | \
    kubectl apply -f -
done

# Workflows
for wf in docker google-cloud-buildpacks ballerina-buildpack react; do
  kubectl get workflows.openchoreo.dev $wf -o yaml | \
    yq eval "del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .status) | .metadata.namespace = \"$NAMESPACE_NAME\"" - | \
    kubectl apply -f -
done
```

### Create Environments

```bash
kubectl apply -f - <<EOF
apiVersion: openchoreo.dev/v1alpha1
kind: Environment
metadata:
  name: development
  namespace: $NAMESPACE_NAME
  annotations:
    openchoreo.dev/display-name: Development
  labels:
    openchoreo.dev/name: development
spec:
  dataPlaneRef:
    kind: DataPlane
    name: $DATAPLANE_NAME
  isProduction: false
EOF
```

Repeat for staging, production, etc. Set `isProduction: true` for production environments.

### Create a DeploymentPipeline

```bash
kubectl apply -f - <<EOF
apiVersion: openchoreo.dev/v1alpha1
kind: DeploymentPipeline
metadata:
  name: default
  namespace: $NAMESPACE_NAME
  annotations:
    openchoreo.dev/display-name: "Default Pipeline"
  labels:
    openchoreo.dev/name: default
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
EOF
```

### Create a Project

```bash
kubectl apply -f - <<EOF
apiVersion: openchoreo.dev/v1alpha1
kind: Project
metadata:
  name: default
  namespace: $NAMESPACE_NAME
  annotations:
    openchoreo.dev/display-name: "Default Project"
  labels:
    openchoreo.dev/name: default
spec:
  deploymentPipelineRef: default
EOF
```

`deploymentPipelineRef` is a plain string, not an object.

### Optional: Register BuildPlane and ObservabilityPlane

Same pattern as DataPlane: extract agent CA, create the CR with `clusterAgent.clientCA.value`.

```bash
# BuildPlane
BP_CA_CERT=$(kubectl --context ${BUILD_PLANE_CONTEXT} get secret cluster-agent-tls \
  -n openchoreo-build-plane \
  -o jsonpath='{.data.ca\.crt}' | base64 -d)

kubectl apply -f - <<EOF
apiVersion: openchoreo.dev/v1alpha1
kind: BuildPlane
metadata:
  name: default
  namespace: $NAMESPACE_NAME
spec:
  planeID: default
  clusterAgent:
    clientCA:
      value: |
$(echo "$BP_CA_CERT" | sed 's/^/        /')
  secretStoreRef:
    name: default
EOF
```

ObservabilityPlane also needs an `observerURL` pointing to the Observer API endpoint.

## Deployment Topology

### Requirements

- Kubernetes 1.32+
- Minimum 3 nodes (HA), 4 CPU / 8 GB RAM per node
- LoadBalancer service type
- Default StorageClass
- cert-manager 1.12+ on all clusters
- Gateway API CRDs on clusters exposing gateways

### Resource allocation (minimums)

| Component | CPU req/limit | Memory req/limit |
|-----------|--------------|-----------------|
| Backstage | 200m / 2000m | 256Mi / 2Gi |
| OpenChoreo API | 200m / 1000m | 256Mi / 1Gi |
| Controller Manager | 200m / 1000m | 256Mi / 1Gi |
| Cluster Gateway | 100m / 500m | 64Mi / 256Mi |
| KGateway Controller | 100m / 200m | 128Mi / 256Mi |
| Cluster Agent | 50m / 100m | 128Mi / 256Mi |
| OpenSearch (per node) | 100m / 1000m | 1Gi / 1Gi |

### Port requirements

- Control Plane: 443 (Backstage, API, IdP), 80 (redirect)
- Data Plane: 443 (app endpoints), 80 (redirect)
- Observability Plane: 443 (OpenSearch ingestion)
- Build Plane: outbound only

### Topology options

**Single-cluster**: All planes in one cluster. Components communicate via ClusterIP.

**Multi-cluster**: Separate clusters per plane. Agents connect via WebSocket to Cluster Gateway. See [Multi-Cluster Connectivity](#multi-cluster-connectivity).

**Hybrid**: Control + Build + Observability together, remote Data Planes.

**Multi-region**: Central Control Plane, regional Data Planes with unique `gateway.publicVirtualHost` per region.

### Installation order

1. Control Plane (configure Cluster Gateway certificate SANs)
2. Extract Control Plane CA, establish trust
3. Observability Plane (if multi-cluster)
4. Data Plane(s)
5. Build Plane

## Multi-Cluster Connectivity

Remote plane agents connect to the Control Plane's Cluster Gateway via WebSocket with mTLS.

### Step 1: Configure Cluster Gateway SANs

During Control Plane install, add the public DNS name:

```bash
helm upgrade --install openchoreo-control-plane \
  oci://ghcr.io/openchoreo/helm-charts/openchoreo-control-plane \
  --namespace openchoreo-control-plane \
  --set "clusterGateway.tls.dnsNames[0]=cluster-gateway.openchoreo-control-plane.svc" \
  --set "clusterGateway.tls.dnsNames[1]=cluster-gateway.openchoreo-control-plane.svc.cluster.local" \
  --set "clusterGateway.tls.dnsNames[2]=cluster-gateway.openchoreo.${DOMAIN}"
```

If connecting by IP instead of DNS, patch the Certificate resource to add IP SANs.

### Step 2: Extract Control Plane CA

```bash
CP_CA_CERT=$(kubectl --context $CP_CONTEXT get secret cluster-gateway-ca \
  -n openchoreo-control-plane \
  -o jsonpath='{.data.ca\.crt}' | base64 -d)

echo "$CP_CA_CERT" > ./server-ca.crt
```

### Step 3: Install remote plane with CA trust

```bash
# Create namespace and ConfigMap with CP CA
kubectl --context $DP_CONTEXT create namespace openchoreo-data-plane
kubectl --context $DP_CONTEXT create configmap cluster-gateway-ca \
  --from-file=ca.crt=./server-ca.crt \
  -n openchoreo-data-plane

# Install with agent config
helm upgrade --install openchoreo-data-plane \
  oci://ghcr.io/openchoreo/helm-charts/openchoreo-data-plane \
  --version <version> \
  --kube-context $DP_CONTEXT \
  --namespace openchoreo-data-plane \
  --set clusterAgent.enabled=true \
  --set clusterAgent.serverUrl="wss://cluster-gateway.openchoreo.${DOMAIN}/ws" \
  --set clusterAgent.tls.enabled=true \
  --set clusterAgent.tls.generateCerts=true \
  --set clusterAgent.tls.serverCAConfigMap=cluster-gateway-ca \
  --set clusterAgent.tls.caSecretName=""
```

### Step 4: Extract agent CA and register

```bash
# Wait for cert generation
kubectl --context $DP_CONTEXT wait --for=condition=Ready \
  certificate/cluster-agent-dataplane-tls -n openchoreo-data-plane --timeout=120s

# Extract agent CA
AGENT_CA=$(kubectl --context $DP_CONTEXT get secret cluster-agent-tls \
  -n openchoreo-data-plane \
  -o jsonpath='{.data.ca\.crt}' | base64 -d)
```

Then create the DataPlane CR in the Control Plane with `clusterAgent.clientCA.value` set to the extracted CA (see [Register a DataPlane](#register-a-dataplane)).

### Step 5: Verify connectivity

```bash
kubectl --context $DP_CONTEXT logs -n openchoreo-data-plane -l app=cluster-agent --tail=20
# Should show "connected to control plane"
```

Same pattern applies for BuildPlane and ObservabilityPlane agents.

### Telemetry in multi-cluster

Data and Build plane exporters point to the Observability Plane's external endpoints. Configure via Helm:

- `fluent-bit.config.outputs` for log forwarding
- `prometheus.prometheusSpec.remoteWrite` for metrics
- `observability.observabilityPlaneUrl` for the Observer API

## Upgrades

### Before upgrading

1. Review release notes for the target version
2. Back up resources:
   ```bash
   kubectl get organizations,projects,components,dataplanes,buildplanes -A -o yaml > openchoreo-backup.yaml
   ```
3. Test in non-production first

### Upgrade procedure

Always upgrade Control Plane first:

```bash
# Control Plane
helm upgrade openchoreo-control-plane \
  oci://ghcr.io/openchoreo/helm-charts/openchoreo-control-plane \
  --version <version> \
  --namespace openchoreo-control-plane \
  --reuse-values
kubectl rollout status deployment -n openchoreo-control-plane

# Data Plane(s)
helm upgrade openchoreo-data-plane \
  oci://ghcr.io/openchoreo/helm-charts/openchoreo-data-plane \
  --version <version> \
  --namespace openchoreo-data-plane \
  --reuse-values

# Build Plane (if installed)
helm upgrade openchoreo-build-plane \
  oci://ghcr.io/openchoreo/helm-charts/openchoreo-build-plane \
  --version <version> \
  --namespace openchoreo-build-plane \
  --reuse-values

# Observability Plane (if installed)
helm upgrade openchoreo-observability-plane \
  oci://ghcr.io/openchoreo/helm-charts/openchoreo-observability-plane \
  --version <version> \
  --namespace openchoreo-observability-plane \
  --reuse-values
```

For multi-cluster, add `--kube-context` for each cluster.

### Verify

```bash
helm list -A
kubectl get pods -n openchoreo-control-plane
kubectl get pods -n openchoreo-data-plane
kubectl get crds | grep openchoreo
```

### Rollback

```bash
helm history openchoreo-control-plane -n openchoreo-control-plane
helm rollback openchoreo-control-plane -n openchoreo-control-plane
```

### Version compatibility

| OpenChoreo | Kubernetes | Helm |
|-----------|-----------|------|
| 0.7.x | 1.32+ | 3.12+ |
| 0.6.x | 1.31+ | 3.12+ |
| 0.5.x | 1.30+ | 3.12+ |
