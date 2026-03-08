# Observability

## Table of Contents

- [Stack Overview](#stack-overview)
- [Installation](#installation)
- [Log Collection](#log-collection)
- [Metrics](#metrics)
- [Traces](#traces)
- [Alerting](#alerting)
- [Notification Channels](#notification-channels)
- [Dashboards](#dashboards)

## Stack Overview

| Signal | Collector | Storage | Query |
|--------|-----------|---------|-------|
| Logs | Fluent Bit | OpenSearch | Observer API |
| Metrics | Prometheus / kube-state-metrics | Prometheus | Observer API |
| Traces | OpenTelemetry Collector | OpenSearch | Observer API |

Single-cluster: collectors run in the same cluster as storage.
Multi-cluster: Data/Build plane collectors forward to the Observability Plane's external endpoints.

## Installation

```bash
helm upgrade --install openchoreo-observability-plane \
  oci://ghcr.io/openchoreo/helm-charts/openchoreo-observability-plane \
  --version <version> \
  --namespace openchoreo-observability-plane \
  --create-namespace \
  --set openSearchCluster.enabled=true
```

Register in the Control Plane namespace with an ObservabilityPlane CR (same pattern as DataPlane: extract agent CA, embed in CR, set `observerURL`).

## Log Collection

Fluent Bit collects container logs and enriches them with Kubernetes metadata. Default retention: 30 days.

Customizable via Helm values:
- `fluent-bit.config.inputs` - log sources
- `fluent-bit.config.filters` - processing/enrichment
- `fluent-bit.config.outputs` - destinations

For multi-cluster, point outputs to the Observability Plane's OpenSearch endpoint.

## Metrics

Prometheus runs in agent mode, scraping cAdvisor (CPU/memory) and Cilium Hubble (HTTP metrics if enabled).

For multi-cluster, configure `prometheus.prometheusSpec.remoteWrite` to forward to the Observability Plane.

## Traces

OpenTelemetry Collector receives traces via OTLP:
- gRPC: port 4317
- HTTP: port 4318

In-cluster endpoints for applications:
- HTTP: `http://opentelemetry-collector.openchoreo-observability-plane.svc.cluster.local:4318/v1/traces`
- gRPC: `opentelemetry-collector.openchoreo-observability-plane.svc.cluster.local:4317`

Tail-based sampling is configurable via Helm:

```yaml
opentelemetryCollectorCustomizations:
  tailSampling:
    decisionWait: 10s
    numTraces: 100
    expectedNewTracesPerSec: 10
    spansPerSecond: 10
```

## Alerting

Alerts are configured via the `observability-alertrule` Trait on components.

### Alert rule parameters

```yaml
traits:
  - name: observability-alertrule
    kind: Trait
    instanceName: high-error-rate
    parameters:
      description: "Error logs > 50 in 5 minutes"
      severity: "critical"       # critical | warning | info
      source:
        type: "log"              # log | metric
        query: "status:error"
      condition:
        window: 5m
        interval: 1m
        operator: gt             # gt | lt | gte | lte | eq
        threshold: 50
```

### Per-environment overrides via ReleaseBinding

```yaml
spec:
  traitOverrides:
    high-error-rate:
      enabled: true
      enableAiRootCauseAnalysis: false
      notificationChannel: devops-email
```

### AI Root Cause Analysis

Enable `enableAiRootCauseAnalysis` on alert rules. The RCA Agent analyzes triggered alerts, queries logs/metrics, and generates reports. Requires the `rca-agent` authorization binding.

## Notification Channels

### Email

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ObservabilityAlertsNotificationChannel
metadata:
  name: devops-email
  namespace: default
spec:
  environment: development
  isEnvDefault: true
  type: email
  emailConfig:
    from: alerts@example.com
    to:
      - team@example.com
    smtp:
      host: smtp.example.com
      port: 587
      auth:
        username:
          secretKeyRef:
            name: smtp-credentials
            key: username
        password:
          secretKeyRef:
            name: smtp-credentials
            key: password
      tls:
        insecureSkipVerify: false
    template:
      subject: "[${alertSeverity}] ${alertName} Triggered"
      body: |
        Alert: ${alertName}
        Severity: ${alertSeverity}
        Time: ${alertTimestamp}
        Component: ${component}
        Project: ${project}
        Environment: ${environment}
```

### Webhook

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ObservabilityAlertsNotificationChannel
metadata:
  name: slack-webhook
  namespace: default
spec:
  environment: development
  isEnvDefault: false
  type: webhook
  webhookConfig:
    url: https://hooks.slack.com/services/xxx
    headers:
      Authorization:
        valueFrom:
          secretKeyRef:
            name: webhook-token
            key: token
    payloadTemplate: |
      {
        "alertName": "${alertName}",
        "severity": "${alertSeverity}",
        "description": "${alertDescription}"
      }
```

Template variables available: `${alertName}`, `${alertSeverity}`, `${alertTimestamp}`, `${alertDescription}`, `${component}`, `${project}`, `${environment}`.

## Dashboards

### OpenSearch Dashboards

```bash
# Enable
helm upgrade openchoreo-observability-plane \
  oci://ghcr.io/openchoreo/helm-charts/openchoreo-observability-plane \
  --namespace openchoreo-observability-plane \
  --reuse-values \
  --set openSearchCluster.dashboards.enable=true

# Access
kubectl port-forward svc/opensearch-dashboards 5601:5601 \
  -n openchoreo-observability-plane
# Open http://localhost:5601
```

### Grafana

```bash
# Enable
helm upgrade openchoreo-observability-plane \
  oci://ghcr.io/openchoreo/helm-charts/openchoreo-observability-plane \
  --namespace openchoreo-observability-plane \
  --reuse-values \
  --set prometheus.grafana.enabled=true

# Access
kubectl port-forward svc/grafana 5000:80 \
  -n openchoreo-observability-plane
# Open http://localhost:5000 (admin/admin)
```
