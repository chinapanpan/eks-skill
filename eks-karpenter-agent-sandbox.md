# Skill: Deploy EKS + Karpenter + Agent Sandbox Cluster

Deploy a production-ready EKS cluster with Karpenter autoscaling and Agent Sandbox warm pool for single-EC2-per-Pod isolation.

## Architecture
- EKS 1.34 (any AWS region)
- VPC: 3 public subnets + 3 private subnets, single NAT Gateway
- All worker nodes in private subnets
- Karpenter v1.9.0 for node autoscaling (single pod per EC2)
- Agent Sandbox v0.2.1 for warm pool and instant pod claim
- EBS CSI Driver + ALB Controller as core add-ons

## Parameters
The user can customize these values. Use these defaults if not specified:
- `CLUSTER_NAME`: agent-sandbox-cluster
- `AWS_REGION`: (user must specify, e.g. us-west-2, ap-northeast-1, eu-west-1)
- `K8S_VERSION`: 1.34
- `KARPENTER_VERSION`: 1.9.0
- `AGENT_SANDBOX_VERSION`: v0.2.1
- `WARM_POOL_REPLICAS`: 2
- `INSTANCE_SIZE`: xlarge (do NOT use "large" - insufficient resources after DaemonSet overhead)
- `AVAILABILITY_ZONES`: Auto-detected from the region (first 3 available AZs). Override if needed.

## Execution Steps

### Step 1: Install Prerequisites
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

### Step 2: Set Environment Variables
```bash
export AWS_DEFAULT_REGION="${AWS_REGION}"
export CLUSTER_NAME="${CLUSTER_NAME}"
export KARPENTER_VERSION="${KARPENTER_VERSION}"
export K8S_VERSION="${K8S_VERSION}"
export AWS_PARTITION="aws"
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export KARPENTER_NAMESPACE="kube-system"

# Auto-detect first 3 available AZs in the region
export AVAILABILITY_ZONES=($(aws ec2 describe-availability-zones \
  --region ${AWS_DEFAULT_REGION} \
  --query 'AvailabilityZones[?State==`available`].ZoneName' \
  --output text | tr '\t' '\n' | head -3))
echo "Using AZs: ${AVAILABILITY_ZONES[@]}"
```

### Step 3: Deploy Karpenter CloudFormation Stack
IMPORTANT: Always use `--region` flag explicitly to avoid wrong-region policy creation.
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

### Step 4: Create EKS Cluster
Generate and apply the following eksctl config. Key points:
- `vpc.nat.gateway: Single` for single NAT GW
- `managedNodeGroups[].privateNetworking: true` to place workers in private subnets
- `iamIdentityMappings` for KarpenterNodeRole
- `podIdentityAssociations` for Karpenter controller (5 policies from CF stack)
- `addons: eks-pod-identity-agent`

```bash
eksctl create cluster -f - <<EOF
---
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

### Step 5: Tag Private Subnets for Karpenter
Karpenter's subnetSelectorTerms matches ALL subnets with the discovery tag. Must add a second tag to restrict to private subnets only.
```bash
PRIVATE_SUBNETS=$(aws ec2 describe-subnets --region ${AWS_DEFAULT_REGION} \
  --filters "Name=tag:karpenter.sh/discovery,Values=${CLUSTER_NAME}" \
  --query 'Subnets[?MapPublicIpOnLaunch==`false`].SubnetId' --output text)
for subnet_id in $PRIVATE_SUBNETS; do
  aws ec2 create-tags --resources "$subnet_id" \
    --tags Key=karpenter.sh/discovery/subnet-type,Value=private \
    --region ${AWS_DEFAULT_REGION}
done
```

### Step 6: Install Karpenter via Helm
```bash
CLUSTER_ENDPOINT="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_DEFAULT_REGION}" --query "cluster.endpoint" --output text)"
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

### Step 7: Create Karpenter NodePool and EC2NodeClass
Single-pod-per-node strategy: taint (NoSchedule) + pod anti-affinity + resource sizing.
DO NOT use `kubelet.maxPods: 1` - it blocks DaemonSet pods (kube-proxy, vpc-cni, ebs-csi).
```bash
ALIAS_VERSION=$(aws ssm get-parameter --region ${AWS_DEFAULT_REGION} \
  --name "/aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/x86_64/standard/recommended/image_id" \
  --query Parameter.Value --output text | \
  xargs -I{} aws ec2 describe-images --region ${AWS_DEFAULT_REGION} --query 'Images[0].Name' --image-ids {} --output text | \
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

### Step 8: Install EBS CSI Driver
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

### Step 9: Install ALB Controller
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

### Step 10: Install Agent Sandbox
```bash
export AGENT_SANDBOX_VERSION="${AGENT_SANDBOX_VERSION}"
kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/manifest.yaml
kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/extensions.yaml
```

### Step 11: Configure SandboxTemplate and Warm Pool
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

### Step 12: Verification
Run these checks to verify the deployment:
```bash
# All components running
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
kubectl get pods -n kube-system | grep ebs-csi
kubectl get pods -n agent-sandbox-system

# Karpenter nodes and warm pool
kubectl get nodeclaims
kubectl get sandboxwarmpools -n default

# Verify single-pod-per-node
kubectl get pods -n default -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName'

# Verify private subnet placement (no external IPs)
kubectl get nodes -l node-type=agent-sandbox -o custom-columns='NAME:.metadata.name,EXTERNAL-IP:.status.addresses[?(@.type=="ExternalIP")].address'

# Test SandboxClaim
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
sleep 3
kubectl get sandboxclaims -n default
kubectl get sandboxwarmpools -n default
# Clean up test
kubectl delete sandboxclaim test-claim -n default
```

## Cleanup
```bash
kubectl delete sandboxwarmpool agent-warm-pool -n default
kubectl delete sandboxtemplate agent-template -n default
kubectl delete sandboxclaim --all -n default
kubectl delete -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/extensions.yaml
kubectl delete -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/manifest.yaml
kubectl delete nodepool agent-sandbox-pool
kubectl delete ec2nodeclass agent-sandbox
helm uninstall aws-load-balancer-controller -n kube-system
helm uninstall karpenter -n kube-system
aws cloudformation delete-stack --stack-name "Karpenter-${CLUSTER_NAME}" --region ${AWS_DEFAULT_REGION}
eksctl delete cluster --name ${CLUSTER_NAME} --region ${AWS_DEFAULT_REGION}
```

## Known Pitfalls
1. **CloudFormation region**: Always pass `--region` explicitly to `aws cloudformation deploy`. If `AWS_DEFAULT_REGION` is not properly exported in a subshell, IAM policies will be scoped to the wrong region.
2. **maxPods: 1**: DO NOT set `kubelet.maxPods: 1` in EC2NodeClass. DaemonSets (kube-proxy, vpc-cni, ebs-csi-node) also need pod slots. Use resource sizing + anti-affinity instead.
3. **Instance size**: "large" (2 vCPU) is too small after system/DaemonSet overhead. Use "xlarge" (4 vCPU, 16GB) or larger.
4. **Private subnet selection**: All subnets tagged with `karpenter.sh/discovery` are candidates. Add a second tag `karpenter.sh/discovery/subnet-type=private` to restrict to private subnets only.
5. **Orphaned IAM resources**: If CF stack deletion fails, IAM resources (policies, roles) may remain as global resources. Delete them manually before re-creating.
6. **Availability zones**: AZs vary by region (Tokyo: a/c/d, Oregon: a/b/c). The skill auto-detects the first 3 available AZs via `aws ec2 describe-availability-zones`.
