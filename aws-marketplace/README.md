# OpenChoreo AWS Marketplace Deployment

Two-phase deployment: Phase 1 creates all infrastructure with self-signed TLS,
Phase 2 (optional) swaps to real certificates from Let's Encrypt.

```
Phase 1 (CloudFormation) → infra + self-signed certs → CREATE_COMPLETE
         ↓
User creates 3 DNS A records (any DNS provider)
         ↓
Phase 2 (CloudFormation) → real TLS certs via ACME → CREATE_COMPLETE
```

## Prerequisites

- AWS account with admin access
- A domain name you control
- AWS CLI configured (`aws configure`)

## Phase 1: Deploy Infrastructure

```bash
aws cloudformation create-stack \
  --stack-name openchoreo \
  --template-body file://cloudformation.yaml \
  --parameters \
    ParameterKey=BaseDomain,ParameterValue=openchoreo.example.com \
    ParameterKey=AdminEmail,ParameterValue=admin@example.com \
    ParameterKey=AvailabilityZone1,ParameterValue=us-east-1a \
    ParameterKey=AvailabilityZone2,ParameterValue=us-east-1b \
  --capabilities CAPABILITY_NAMED_IAM
```

This takes ~40-60 minutes. CloudFormation creates the VPC, EKS cluster, RDS,
Cognito, and then CodeBuild bootstraps all Kubernetes components.

Monitor progress in the CodeBuild console (project: `<stack-name>-bootstrap`)
or CloudWatch Logs.

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `BaseDomain` | (required) | Your domain |
| `AdminEmail` | (required) | Admin user email (receives Cognito password) |
| `OpenChoreoVersion` | `0.16.0` | Release version |
| `EKSVersion` | `1.33` | EKS Kubernetes version |
| `NodeInstanceType` | `m5.xlarge` | EC2 instance type for nodes |
| `NodeCount` | `3` | Number of worker nodes (min 3) |
| `NodeDiskSize` | `100` | Node disk size in GB |
| `RDSInstanceClass` | `db.t4g.medium` | RDS instance class |
| `AvailabilityZone1` | (required) | First AZ |
| `AvailabilityZone2` | (required) | Second AZ |

### Outputs

After `CREATE_COMPLETE`, check the stack outputs for IP addresses:

```bash
aws cloudformation describe-stacks --stack-name openchoreo \
  --query 'Stacks[0].Outputs[?OutputKey==`DNSInstructions`].OutputValue' \
  --output text
```

## DNS Setup

Create three A records with your DNS provider. The IPs come from the stack outputs
(`ControlPlaneIP` and `DataPlaneIP`):

| Record | Type | Value |
|--------|------|-------|
| `console.<domain>` | A | Control Plane IP |
| `api.<domain>` | A | Control Plane IP |
| `*.apps.<domain>` | A | Data Plane IP |

At this point the console is accessible at `https://console.<domain>` with a
self-signed certificate (browser will show a warning).

## Phase 2: Activate TLS (optional)

Once DNS is propagated, deploy the TLS stack to get real certificates:

### Option A: Cloudflare DNS

```bash
aws cloudformation create-stack \
  --stack-name openchoreo-tls \
  --template-body file://cloudformation-tls.yaml \
  --parameters \
    ParameterKey=Phase1StackName,ParameterValue=openchoreo \
    ParameterKey=TLSMethod,ParameterValue=cloudflare \
    ParameterKey=CloudflareApiToken,ParameterValue=YOUR_TOKEN \
    ParameterKey=AdminEmail,ParameterValue=admin@example.com \
  --capabilities CAPABILITY_NAMED_IAM
```

### Option B: Route53 DNS

```bash
aws cloudformation create-stack \
  --stack-name openchoreo-tls \
  --template-body file://cloudformation-tls.yaml \
  --parameters \
    ParameterKey=Phase1StackName,ParameterValue=openchoreo \
    ParameterKey=TLSMethod,ParameterValue=route53 \
    ParameterKey=Route53HostedZoneId,ParameterValue=Z0123456789 \
    ParameterKey=AdminEmail,ParameterValue=admin@example.com \
  --capabilities CAPABILITY_NAMED_IAM
```

Takes ~5-10 minutes. After completion, the console works without cert warnings.

## Verification

```bash
# Configure kubectl
aws eks update-kubeconfig --name openchoreo

# Check all pods
kubectl get pods -A | grep openchoreo

# Check certificates
kubectl get certificates -A

# Check planes
kubectl get dataplane,buildplane,observabilityplane
```

## User Management

The admin user receives a temporary password via email. Additional users:

```bash
POOL_ID=$(aws cloudformation describe-stacks --stack-name openchoreo \
  --query 'Stacks[0].Outputs[?OutputKey==`CognitoUserPoolId`].OutputValue' \
  --output text)

# Create user
aws cognito-idp admin-create-user \
  --user-pool-id $POOL_ID \
  --username user@example.com \
  --user-attributes Name=email,Value=user@example.com Name=email_verified,Value=true

# Add to group (admin, developer, or viewer)
aws cognito-idp admin-add-user-to-group \
  --user-pool-id $POOL_ID \
  --username user@example.com \
  --group-name developer
```

## Cleanup

Delete in reverse order. Phase 2 first (if deployed), then Phase 1:

```bash
# Delete Phase 2 (if deployed)
aws cloudformation delete-stack --stack-name openchoreo-tls
aws cloudformation wait stack-delete-complete --stack-name openchoreo-tls

# Delete Phase 1
aws cloudformation delete-stack --stack-name openchoreo
aws cloudformation wait stack-delete-complete --stack-name openchoreo
```

Phase 1 deletion triggers a CodeBuild cleanup job that helm-uninstalls everything
and removes NLBs before CloudFormation deletes the EKS cluster and VPC.

Takes ~15-20 minutes total.

## Troubleshooting

### Bootstrap stuck or failed

Check CodeBuild logs:

```bash
# Find the build ID
aws codebuild list-builds-for-project \
  --project-name openchoreo-bootstrap \
  --query 'ids[0]' --output text

# Stream logs
aws codebuild batch-get-builds --ids <build-id> \
  --query 'builds[0].logs.deepLink' --output text
```

Or check CloudWatch Logs group: `/aws/codebuild/openchoreo-bootstrap`

### Certificates not ready

```bash
kubectl get certificates -A
kubectl describe certificate control-plane-tls -n openchoreo-control-plane
kubectl get challenges -A
```

For ACME certificates, DNS must be propagated before cert-manager can validate.
Check `kubectl get challenges -A` for pending DNS-01 challenges.

### Stack deletion fails

If cleanup CodeBuild fails, the stack may show `DELETE_FAILED`. Retry:

```bash
aws cloudformation delete-stack --stack-name openchoreo
```

If NLBs are stuck, manually delete them in the EC2 console, then retry.

### Pods not starting

```bash
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace>
```

Common issues: node capacity (increase `NodeCount`), disk space (increase
`NodeDiskSize`), or RDS connectivity (check security groups).
