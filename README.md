# EKS + Karpenter + Agent Sandbox

Deploy production-ready EKS clusters with single-EC2-per-Pod isolation using Karpenter and Agent Sandbox warm pools.

## Repository Structure

```
eks-skill/
├── setup_guide.md           # Step-by-step deployment guide (11 steps)
├── sandbox_usage_guide.md   # Agent Sandbox usage guide (post-install)
├── tests/
│   └── test-all.sh          # Validation test suite (15 tests)
└── README.md
```

## What This Deploys

- **EKS 1.34** cluster with VPC (3 public + 3 private subnets, single NAT Gateway)
- **Karpenter v1.9.0** for node autoscaling with single-pod-per-node isolation
- **Agent Sandbox v0.2.1** with warm pool for sub-2s sandbox claim latency
- **EBS CSI Driver** + **ALB Controller** as add-ons
- Worker nodes in **private subnets only**

## Instance Type Profiles

| Profile | INSTANCE_TYPE | vCPU / RAM | SandboxTemplate Resources | Use Case |
|---------|---------------|------------|---------------------------|----------|
| **Standard** | `m5.xlarge` | 4 vCPU / 16GB | cpu: 3500m, mem: 12Gi | Production workloads |
| **Low-spec** | `t3.medium` | 2 vCPU / 4GB | cpu: 1, mem: 2Gi | Dev/test, cost-sensitive |

Both profiles verified: pods run successfully with 1 pod per dedicated node.

## Key Features

- **Region-portable**: Works in any AWS commercial region (auto-detects AZs)
- **Account-portable**: No hardcoded account IDs; uses `${AWS_ACCOUNT_ID}`, `${AWS_PARTITION}`
- **Single-pod-per-node isolation**: Triple guarantee via node taint + pod anti-affinity + resource sizing
- **Warm pool**: Pre-provisioned sandboxes for instant (~1-2s) claim vs ~90s cold start

## Quick Start

1. Follow **[setup_guide.md](setup_guide.md)** for the full 11-step deployment
2. Set your parameters:
   ```bash
   export AWS_DEFAULT_REGION="us-west-2"
   export CLUSTER_NAME="my-agent-cluster"
   export INSTANCE_TYPE="m5.xlarge"    # or t3.medium for low-cost
   ```
3. After deployment, see **[sandbox_usage_guide.md](sandbox_usage_guide.md)** for sandbox operations

## Guides

- **[Setup Guide](setup_guide.md)**: Prerequisites, parameters, step-by-step deployment, troubleshooting, cleanup, and cost estimates.
- **[Sandbox Usage Guide](sandbox_usage_guide.md)**: Concepts, SandboxTemplate/WarmPool/Claim usage, monitoring, advanced use cases (custom images, multiple pools, burst scaling, Python SDK), and full API reference.

## Test Suite

```bash
TEST_REGION=<your-region> TEST_CLUSTER_NAME=<your-cluster> bash tests/test-all.sh
```

15 tests in 3 groups:
- **Karpenter** (5): scale-out, single-pod-per-node, private subnets, taints, scale-in
- **ALB Controller** (4): deployment health, IngressClass, ALB provisioning, HTTP response
- **Agent Sandbox** (6): controller health, warm pool ready, claim latency, backfill, burst claims, cleanup

## Cost Estimate

| Profile | Idle cost (2 warm pool pods) | Daily |
|---------|------------------------------|-------|
| Standard (m5.xlarge) | ~$0.72/hr | ~$17/day |
| Low-spec (t3.medium) | ~$0.42/hr | ~$10/day |

Scale warm pool to 0 when not in use to reduce to ~$0.34/hr.
