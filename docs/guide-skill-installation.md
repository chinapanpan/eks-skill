# EKS + Karpenter + Agent Sandbox: Skill Installation & Usage Guide

## Overview

This guide walks you through deploying a production-ready EKS cluster with:
- **Karpenter** for dynamic node autoscaling
- **Agent Sandbox** for warm pool and instant pod claim
- **Single EC2 per Pod** isolation for maximum security
- **EBS CSI Driver** for persistent storage
- **ALB Controller** for ingress load balancing

The deployment is fully automated via a Claude Code skill and works in any AWS region.

---

## Architecture

```
                     +---------------------------+
                     |     EKS Control Plane      |
                     |       (EKS 1.34)           |
                     +---------------------------+
                                |
               +----------------+----------------+
               |                                 |
     +---------+----------+           +----------+---------+
     | Managed Node Group |           |  Karpenter Nodes   |
     |   (m5.large x2)    |           |  (xlarge, dynamic) |
     |  system workloads   |           |  1 pod per node    |
     +--------------------+           +--------------------+
                                              |
                                    +---------+---------+
                                    |  Agent Sandbox    |
                                    |  Warm Pool (N)    |
                                    |                   |
                                    | SandboxClaim -->  |
                                    | instant pod bind  |
                                    +-------------------+
```

**VPC Layout:**
- 3 public subnets (NAT Gateway, ALB)
- 3 private subnets (all worker nodes)
- Single NAT Gateway (cost-optimized)

---

## Prerequisites

### AWS Requirements
- AWS account with admin-level IAM permissions
- EC2 instance (or local machine) with AWS CLI configured
- IAM role or credentials with the following capabilities:
  - CloudFormation (create/delete stacks)
  - EKS (create/delete clusters)
  - EC2 (describe/create instances, subnets, security groups)
  - IAM (create roles, policies, service accounts)
  - SQS (for Karpenter interruption queue)

### Tools Required
The skill installs these automatically in Step 1:
| Tool | Minimum Version | Purpose |
|------|----------------|---------|
| kubectl | 1.28+ | Kubernetes CLI |
| eksctl | 0.170+ | EKS cluster management |
| helm | 3.12+ | Kubernetes package manager |
| aws-cli | 2.x | AWS API access |
| curl | any | Download scripts |

---

## Parameters Reference

All parameters can be customized. Defaults are shown below.

| Parameter | Default | Constraints | Description |
|-----------|---------|-------------|-------------|
| `CLUSTER_NAME` | `agent-sandbox-cluster` | 1-100 chars, alphanumeric + hyphens | EKS cluster name |
| `AWS_REGION` | (user specifies) | Any AWS region with EKS 1.34 | Deployment region |
| `K8S_VERSION` | `1.34` | Must be supported by EKS | Kubernetes version |
| `KARPENTER_VERSION` | `1.9.0` | >= 1.6 for EKS 1.34 | Karpenter Helm chart version |
| `AGENT_SANDBOX_VERSION` | `v0.2.1` | Valid release tag | Agent Sandbox release |
| `WARM_POOL_REPLICAS` | `2` | >= 1 | Pre-provisioned sandbox pods |
| `INSTANCE_SIZE` | `xlarge` | xlarge or larger | EC2 instance size for sandbox nodes |
| `AVAILABILITY_ZONES` | Auto-detected | 3 AZs required | Auto-detected from region |

### Important Constraints
- **INSTANCE_SIZE**: Do NOT use `large` (2 vCPU). DaemonSet overhead leaves insufficient resources. Use `xlarge` (4 vCPU, 16GB) minimum.
- **AVAILABILITY_ZONES**: Auto-detected via `aws ec2 describe-availability-zones`. Different regions have different AZ naming (e.g., Tokyo: a/c/d, Oregon: a/b/c).

---

## Step-by-Step Usage

### Step 1: Install Prerequisites (~2 min)

```bash
# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# eksctl
ARCH=amd64 && PLATFORM=$(uname -s)_$ARCH
curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$PLATFORM.tar.gz"
tar -xzf eksctl_$PLATFORM.tar.gz -C /tmp && sudo mv /tmp/eksctl /usr/local/bin
rm -f eksctl_$PLATFORM.tar.gz

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

**Expected output**: Version numbers printed for each tool.

### Step 2: Set Environment Variables (~1 min)

```bash
export AWS_DEFAULT_REGION="<your-region>"       # e.g. us-west-2, ap-northeast-1, eu-west-1
export CLUSTER_NAME="my-agent-cluster"          # Change to your cluster name
export KARPENTER_VERSION="1.9.0"
export K8S_VERSION="1.34"
export AWS_PARTITION="aws"
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export KARPENTER_NAMESPACE="kube-system"
export INSTANCE_SIZE="xlarge"
export WARM_POOL_REPLICAS=2

# Auto-detect AZs
export AVAILABILITY_ZONES=($(aws ec2 describe-availability-zones \
  --region ${AWS_DEFAULT_REGION} \
  --query 'AvailabilityZones[?State==`available`].ZoneName' \
  --output text | tr '\t' '\n' | head -3))
echo "Using AZs: ${AVAILABILITY_ZONES[@]}"
```

**Expected output**: Account ID and 3 AZ names.

### Step 3: Deploy Karpenter IAM Resources (~2 min)

```bash
TEMPOUT="$(mktemp)"
curl -fsSL "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml" > "${TEMPOUT}"
aws cloudformation deploy \
  --stack-name "Karpenter-${CLUSTER_NAME}" \
  --template-file "${TEMPOUT}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides "ClusterName=${CLUSTER_NAME}" \
  --region "${AWS_DEFAULT_REGION}"
```

**Expected output**: `Successfully created/updated stack - Karpenter-<cluster-name>`

### Step 4: Create EKS Cluster (~15-20 min)

This is the longest step. The eksctl command creates:
- VPC with 3 public + 3 private subnets
- Single NAT Gateway
- EKS control plane
- Managed node group (2x m5.large in private subnets)
- Pod identity associations for Karpenter

```bash
eksctl create cluster -f - <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_DEFAULT_REGION}
  version: "${K8S_VERSION}"
  tags:
    karpenter.sh/discovery: ${CLUSTER_NAME}
vpc:
  nat:
    gateway: Single
  clusterEndpoints:
    publicAccess: true
    privateAccess: true
availabilityZones:
  - ${AVAILABILITY_ZONES[0]}
  - ${AVAILABILITY_ZONES[1]}
  - ${AVAILABILITY_ZONES[2]}
iam:
  withOIDC: true
  podIdentityAssociations:
  - namespace: "${KARPENTER_NAMESPACE}"
    serviceAccountName: karpenter
    roleName: ${CLUSTER_NAME}-karpenter
    permissionPolicyARNs:
    - arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerNodeLifecyclePolicy-${CLUSTER_NAME}
    - arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerIAMIntegrationPolicy-${CLUSTER_NAME}
    - arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerEKSIntegrationPolicy-${CLUSTER_NAME}
    - arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerInterruptionPolicy-${CLUSTER_NAME}
    - arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerResourceDiscoveryPolicy-${CLUSTER_NAME}
iamIdentityMappings:
- arn: "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}"
  username: system:node:{{EC2PrivateDNSName}}
  groups:
  - system:bootstrappers
  - system:nodes
managedNodeGroups:
- instanceType: m5.large
  amiFamily: AmazonLinux2023
  name: ${CLUSTER_NAME}-ng
  desiredCapacity: 2
  minSize: 1
  maxSize: 5
  privateNetworking: true
addons:
- name: eks-pod-identity-agent
EOF
```

**Expected output**: `EKS cluster "<cluster-name>" in "<region>" region is ready`

### Step 5: Tag Private Subnets (~1 min)

```bash
PRIVATE_SUBNETS=$(aws ec2 describe-subnets --region ${AWS_DEFAULT_REGION} \
  --filters "Name=tag:karpenter.sh/discovery,Values=${CLUSTER_NAME}" \
  --query 'Subnets[?MapPublicIpOnLaunch==`false`].SubnetId' --output text)
for subnet_id in $PRIVATE_SUBNETS; do
  aws ec2 create-tags --resources "$subnet_id" \
    --tags Key=karpenter.sh/discovery/subnet-type,Value=private \
    --region ${AWS_DEFAULT_REGION}
done
echo "Tagged $(echo $PRIVATE_SUBNETS | wc -w) private subnets"
```

**Expected output**: `Tagged 3 private subnets`

### Step 6: Install Karpenter (~2 min)

```bash
CLUSTER_ENDPOINT="$(aws eks describe-cluster --name "${CLUSTER_NAME}" \
  --region "${AWS_DEFAULT_REGION}" --query "cluster.endpoint" --output text)"
aws iam create-service-linked-role --aws-service-name spot.amazonaws.com 2>/dev/null || true
helm registry logout public.ecr.aws 2>/dev/null || true
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace "${KARPENTER_NAMESPACE}" --create-namespace \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.interruptionQueue=${CLUSTER_NAME}" \
  --set "settings.clusterEndpoint=${CLUSTER_ENDPOINT}" \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --wait
```

**Expected output**: `Release "karpenter" has been upgraded. Happy Helming!`

### Step 7: Create NodePool & EC2NodeClass (~1 min)

```bash
ALIAS_VERSION=$(aws ssm get-parameter --region ${AWS_DEFAULT_REGION} \
  --name "/aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/x86_64/standard/recommended/image_id" \
  --query Parameter.Value --output text | \
  xargs -I{} aws ec2 describe-images --region ${AWS_DEFAULT_REGION} \
  --query 'Images[0].Name' --image-ids {} --output text | \
  sed -r 's/^.*(v[[:digit:]]+).*$/\1/')

cat <<EOF | kubectl apply -f -
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: agent-sandbox-pool
spec:
  template:
    metadata:
      labels:
        node-type: agent-sandbox
    spec:
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gte
          values: ["5"]
        - key: karpenter.k8s.aws/instance-size
          operator: In
          values: ["${INSTANCE_SIZE}"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: agent-sandbox
      taints:
        - key: agent-sandbox
          value: "true"
          effect: NoSchedule
      expireAfter: 720h
  limits:
    cpu: "1000"
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 30s
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: agent-sandbox
spec:
  role: "KarpenterNodeRole-${CLUSTER_NAME}"
  amiSelectorTerms:
    - alias: "al2023@${ALIAS_VERSION}"
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}"
        karpenter.sh/discovery/subnet-type: "private"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}"
EOF
```

**Expected output**: `nodepool.karpenter.sh/agent-sandbox-pool created` and `ec2nodeclass.karpenter.k8s.aws/agent-sandbox created`

### Step 8: Install EBS CSI Driver (~3 min)

```bash
eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster ${CLUSTER_NAME} \
  --region ${AWS_DEFAULT_REGION} \
  --role-name AmazonEKS_EBS_CSI_DriverRole-${CLUSTER_NAME} \
  --role-only \
  --attach-policy-arn arn:${AWS_PARTITION}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve

aws eks create-addon \
  --cluster-name ${CLUSTER_NAME} \
  --addon-name aws-ebs-csi-driver \
  --service-account-role-arn "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/AmazonEKS_EBS_CSI_DriverRole-${CLUSTER_NAME}" \
  --region ${AWS_DEFAULT_REGION}
```

**Expected output**: IAM role created + EBS CSI addon created.

### Step 9: Install ALB Controller (~3 min)

```bash
curl -fsSL "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.12.0/docs/install/iam_policy.json" -o /tmp/alb-iam-policy.json
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy-${CLUSTER_NAME} \
  --policy-document file:///tmp/alb-iam-policy.json

eksctl create iamserviceaccount \
  --cluster ${CLUSTER_NAME} \
  --region ${AWS_DEFAULT_REGION} \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --role-name AmazonEKS_ALB_Controller_Role-${CLUSTER_NAME} \
  --attach-policy-arn "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy-${CLUSTER_NAME}" \
  --approve

VPC_ID=$(aws ec2 describe-vpcs --region ${AWS_DEFAULT_REGION} \
  --filters "Name=tag:alpha.eksctl.io/cluster-name,Values=${CLUSTER_NAME}" \
  --query "Vpcs[0].VpcId" --output text)

helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=${CLUSTER_NAME} \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=${AWS_DEFAULT_REGION} \
  --set vpcId=${VPC_ID} \
  --wait
```

**Expected output**: `Release "aws-load-balancer-controller" has been installed. Happy Helming!`

### Step 10: Install Agent Sandbox (~1 min)

```bash
export AGENT_SANDBOX_VERSION="v0.2.1"
kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/manifest.yaml
kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/extensions.yaml
```

**Expected output**: CRDs and controller created in `agent-sandbox-system` namespace.

### Step 11: Configure SandboxTemplate + Warm Pool (~1 min)

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxTemplate
metadata:
  name: agent-template
  namespace: default
spec:
  podTemplate:
    spec:
      tolerations:
      - key: agent-sandbox
        value: "true"
        effect: NoSchedule
      nodeSelector:
        node-type: agent-sandbox
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                agents.x-k8s.io/sandbox-template: agent-template
            topologyKey: kubernetes.io/hostname
      securityContext:
        runAsUser: 1000
        runAsGroup: 3000
        fsGroup: 2000
        runAsNonRoot: true
      containers:
      - name: agent
        image: busybox
        command: ["/bin/sh", "-c", "echo 'Agent sandbox running'; sleep 36000"]
        resources:
          requests:
            cpu: "3500m"
            memory: "12Gi"
          limits:
            cpu: "4"
            memory: "14Gi"
        ports:
        - containerPort: 8080
          protocol: TCP
EOF

cat <<EOF | kubectl apply -f -
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxWarmPool
metadata:
  name: agent-warm-pool
  namespace: default
spec:
  replicas: ${WARM_POOL_REPLICAS}
  sandboxTemplateRef:
    name: agent-template
EOF
```

**Expected output**: SandboxTemplate and SandboxWarmPool created. Karpenter will provision nodes in ~90s.

---

## Verification Checklist

After deployment, verify these:

```bash
# 1. All system pods healthy
kubectl get pods -n kube-system | grep -E 'karpenter|alb|ebs'

# 2. Agent Sandbox controller running
kubectl get pods -n agent-sandbox-system

# 3. Warm pool ready
kubectl get sandboxwarmpools -n default

# 4. Karpenter nodes provisioned (1 per warm pool pod)
kubectl get nodeclaims

# 5. Single pod per node
kubectl get pods -n default -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName'

# 6. Private subnets only (no external IPs)
kubectl get nodes -l node-type=agent-sandbox \
  -o custom-columns='NAME:.metadata.name,EXT-IP:.status.addresses[?(@.type=="ExternalIP")].address'

# 7. Test SandboxClaim
cat <<'EOF' | kubectl apply -f -
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxClaim
metadata:
  name: test-claim
  namespace: default
spec:
  sandboxTemplateRef:
    name: agent-template
  lifecycle:
    shutdownPolicy: Delete
EOF
sleep 3 && kubectl get sandboxclaims -n default
kubectl delete sandboxclaim test-claim -n default
```

You can also run the automated test suite:
```bash
TEST_REGION=${AWS_DEFAULT_REGION} TEST_CLUSTER_NAME=${CLUSTER_NAME} bash ~/tests/test-all.sh
```

---

## Troubleshooting

### Karpenter pods CrashLoopBackOff (403 errors)

**Cause**: CloudFormation stack created with wrong region. IAM policies are scoped to a different region.

**Fix**:
```bash
# Check policy region
aws iam get-policy-version \
  --policy-arn "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerResourceDiscoveryPolicy-${CLUSTER_NAME}" \
  --version-id v1 --query 'PolicyVersion.Document.Statement[0].Condition'

# If wrong region: delete CF stack, clean IAM, redeploy with --region flag
aws cloudformation delete-stack --stack-name "Karpenter-${CLUSTER_NAME}" --region ${AWS_DEFAULT_REGION}
# Wait, then redeploy
```

### Pods stuck in Pending ("no instance type has enough resources")

**Cause 1**: `kubelet.maxPods: 1` in EC2NodeClass blocks DaemonSets.
**Fix**: Remove `maxPods` setting. Use resource sizing + anti-affinity instead.

**Cause 2**: Instance size too small (e.g., "large" with 2 vCPU).
**Fix**: Use "xlarge" (4 vCPU, 16GB) or larger.

### Karpenter nodes in public subnets

**Cause**: All subnets tagged with `karpenter.sh/discovery` are candidates.
**Fix**: Add `karpenter.sh/discovery/subnet-type=private` tag to private subnets only.

### ALB DNS not resolving

**Cause**: DNS propagation delay (2-5 minutes after ALB creation).
**Fix**: Wait and retry. Check `kubectl describe ingress` for `SuccessfullyReconciled` event.

### Orphaned IAM resources after CF stack deletion

**Cause**: IAM resources are global; CF stack deletion may leave them.
**Fix**: Manually delete policies and roles:
```bash
for p in NodeLifecyclePolicy IAMIntegrationPolicy EKSIntegrationPolicy InterruptionPolicy ResourceDiscoveryPolicy; do
  aws iam delete-policy --policy-arn "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterController${p}-${CLUSTER_NAME}"
done
```

---

## Cleanup

```bash
# 1. Delete Agent Sandbox resources
kubectl delete sandboxwarmpool agent-warm-pool -n default
kubectl delete sandboxtemplate agent-template -n default
kubectl delete sandboxclaim --all -n default
kubectl delete -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/extensions.yaml
kubectl delete -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/manifest.yaml

# 2. Delete Karpenter resources
kubectl delete nodepool agent-sandbox-pool
kubectl delete ec2nodeclass agent-sandbox

# 3. Uninstall Helm charts
helm uninstall aws-load-balancer-controller -n kube-system
helm uninstall karpenter -n kube-system

# 4. Delete CF stack
aws cloudformation delete-stack --stack-name "Karpenter-${CLUSTER_NAME}" --region ${AWS_DEFAULT_REGION}

# 5. Delete EKS cluster (also deletes VPC, subnets, nodegroup)
eksctl delete cluster --name ${CLUSTER_NAME} --region ${AWS_DEFAULT_REGION}
```

---

## Cost Estimate

| Component | Instance | Approx. Cost/hr |
|-----------|----------|-----------------|
| EKS Control Plane | - | $0.10/hr |
| Managed Nodegroup | 2x m5.large | ~$0.19/hr (varies by region) |
| Karpenter Nodes | Nx xlarge (on-demand) | ~$0.15-0.20/hr each (varies by region & instance family) |
| NAT Gateway | 1x | ~$0.045/hr + data transfer |
| ALB | 1x (if used) | ~$0.0225/hr + LCU |

**Minimum cost (idle with 2 warm pool pods)**: ~$0.60-0.75/hr (~$15-18/day), varies by region.

Scale to 0 warm pool pods when not in use to reduce cost to ~$0.34/hr. Check [AWS Pricing](https://aws.amazon.com/ec2/pricing/on-demand/) for exact rates in your region.
