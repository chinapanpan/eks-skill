# EKS + Karpenter + Agent Sandbox Skill

A Claude Code skill and guides for deploying production-ready EKS clusters with single-EC2-per-Pod isolation using Karpenter and Agent Sandbox warm pools.

## Repository Structure

```
eks-skill/
├── eks-karpenter-agent-sandbox.md   # Claude Code Skill (main deployment script)
├── docs/
│   ├── guide-skill-installation.md  # Skill Installation & Usage Guide
│   └── guide-agent-sandbox-usage.md # Agent Sandbox Usage Guide (post-install)
├── tests/
│   └── test-all.sh                  # Validation test suite (15 tests)
└── README.md
```

## What This Deploys

- **EKS 1.34** cluster with VPC (3 public + 3 private subnets, single NAT Gateway)
- **Karpenter v1.9.0** for node autoscaling with single-pod-per-node isolation
- **Agent Sandbox v0.2.1** with warm pool for sub-2s sandbox claim latency
- **EBS CSI Driver** + **ALB Controller** as add-ons
- Worker nodes in **private subnets only**

## Key Features

- **Region-portable**: Works in any AWS commercial region (auto-detects AZs)
- **Account-portable**: No hardcoded account IDs; uses `${AWS_ACCOUNT_ID}`, `${AWS_PARTITION}`
- **Single-pod-per-node isolation**: Triple guarantee via node taint + pod anti-affinity + resource sizing
- **Warm pool**: Pre-provisioned sandboxes for instant (~1-2s) claim vs ~90s cold start

## Quick Start

1. Install the skill: copy `eks-karpenter-agent-sandbox.md` to `~/.claude/skills/`
2. In Claude Code, ask: *"Deploy an EKS cluster with Karpenter and Agent Sandbox in us-west-2"*
3. Follow the skill steps or see `docs/guide-skill-installation.md` for detailed walkthrough

## Guides

- **[Skill Installation Guide](docs/guide-skill-installation.md)**: Prerequisites, parameters, step-by-step deployment, troubleshooting, cleanup, and cost estimates.
- **[Agent Sandbox Usage Guide](docs/guide-agent-sandbox-usage.md)**: Concepts, SandboxTemplate/WarmPool/Claim usage, monitoring, advanced use cases (custom images, multiple pools, burst scaling, Python SDK), and full API reference.

## Test Suite

```bash
# Run against your cluster
TEST_REGION=<your-region> TEST_CLUSTER_NAME=<your-cluster> bash tests/test-all.sh
```

15 tests in 3 groups:
- **Karpenter** (5): scale-out, single-pod-per-node, private subnets, taints, scale-in
- **ALB Controller** (4): deployment health, IngressClass, ALB provisioning, HTTP response
- **Agent Sandbox** (6): controller health, warm pool ready, claim latency, backfill, burst claims, cleanup

## Validated Regions

| Region | Cluster Name | Result |
|--------|-------------|--------|
| ap-northeast-1 (Tokyo) | agent-sandbox-cluster | 15/15 passed |
| us-west-2 (Oregon) | agent-sandbox-usw2 | 14/15 passed (ALB timing) |
