# Agent Sandbox Usage Guide

This guide covers how to use Agent Sandbox after your EKS + Karpenter environment is deployed.

---

## Core Concepts

### Sandbox
A **Sandbox** is an isolated execution environment (a Kubernetes Pod) for an autonomous AI agent. Each Sandbox:
- Runs on its own dedicated EC2 instance (single-pod-per-node)
- Is isolated from other Sandboxes via node-level separation
- Has secure-by-default networking (blocks internal cluster IPs, VPC subnets, metadata server)

### SandboxTemplate
A **SandboxTemplate** defines the Pod specification that Sandboxes will use. It includes:
- Container image, command, and resource requests
- Node affinity and tolerations for Karpenter nodes
- Pod anti-affinity for single-pod-per-node guarantee
- Security context

### SandboxWarmPool
A **SandboxWarmPool** pre-provisions N Sandboxes based on a SandboxTemplate. When a claim is made, an existing warm pod is instantly bound instead of waiting for a new node (~90s).

### SandboxClaim
A **SandboxClaim** requests a Sandbox from a warm pool. It binds to an available pre-provisioned pod in ~1s instead of the ~90s cold-start.

---

## How It All Works Together

```
1. SandboxTemplate defines the pod spec
2. SandboxWarmPool creates N pods using the template
3. Karpenter sees pending pods -> provisions N new EC2 instances
4. Pods start running on dedicated nodes (warm, idle, ready)
5. User creates SandboxClaim -> instantly binds to a warm pod
6. WarmPool detects shortage -> creates replacement pod
7. Karpenter provisions another node for the new pod
8. When claim is deleted -> Sandbox is released
9. Karpenter detects empty node -> consolidates (deletes node)
```

**Timing:**
| Operation | Latency |
|-----------|---------|
| Cold start (no warm pool) | ~90-120s (EC2 provisioning) |
| Warm pool claim | ~1-2s (pod already running) |
| Warm pool backfill | ~90-120s (new node for replacement) |
| Node scale-in (WhenEmpty) | ~30s after pod removal |

---

## Creating a SandboxTemplate

### Minimal Example

```yaml
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxTemplate
metadata:
  name: my-agent-template
  namespace: default
spec:
  podTemplate:
    spec:
      containers:
      - name: agent
        image: my-agent-image:latest
        command: ["/bin/sh", "-c", "sleep 36000"]
```

### Production Example (with isolation)

```yaml
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxTemplate
metadata:
  name: agent-template
  namespace: default
spec:
  podTemplate:
    spec:
      # Tolerate the Karpenter node taint
      tolerations:
      - key: agent-sandbox
        value: "true"
        effect: NoSchedule

      # Only schedule on Karpenter agent-sandbox nodes
      nodeSelector:
        node-type: agent-sandbox

      # Guarantee: 1 sandbox pod per node
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                agents.x-k8s.io/sandbox-template: agent-template
            topologyKey: kubernetes.io/hostname

      # Non-root security
      securityContext:
        runAsUser: 1000
        runAsGroup: 3000
        fsGroup: 2000
        runAsNonRoot: true

      containers:
      - name: agent
        image: busybox
        command: ["/bin/sh", "-c", "echo 'Agent running'; sleep 36000"]
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
```

### Key Fields Explained

| Field | Purpose | Required? |
|-------|---------|-----------|
| `tolerations` | Allows scheduling on tainted Karpenter nodes | Yes (for Karpenter integration) |
| `nodeSelector` | Restricts to nodes with `node-type: agent-sandbox` label | Yes (for Karpenter integration) |
| `affinity.podAntiAffinity` | Prevents 2 sandbox pods on the same node | Yes (for isolation) |
| `resources.requests` | Size the pod to consume most of the node | Yes (for isolation) |
| `securityContext` | Run as non-root for security | Recommended |

### Why Resource Requests Matter

Resource requests serve a dual purpose:
1. **Kubernetes scheduling**: Tells the scheduler how much CPU/memory the pod needs
2. **Isolation guarantee**: A pod requesting most of the node's resources (e.g., 3500m/12Gi on m5.xlarge, or 1/2Gi on t3.medium) leaves no room for a second sandbox pod

Adjust requests to match your instance type:
| Instance Type | vCPU | Memory | Recommended Request | Use Case |
|---------------|------|--------|---------------------|----------|
| t3.medium | 2 | 4 GiB | 1 CPU, 2Gi mem | Dev/test, low-cost |
| m5.xlarge | 4 | 16 GiB | 3500m CPU, 12Gi mem | Production (default) |
| m5.2xlarge | 8 | 32 GiB | 7500m CPU, 28Gi mem | Heavy workloads |
| m5.4xlarge | 16 | 64 GiB | 15000m CPU, 56Gi mem | Large models |

---

## Configuring the Warm Pool

### Basic Warm Pool

```yaml
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxWarmPool
metadata:
  name: agent-warm-pool
  namespace: default
spec:
  replicas: 2
  sandboxTemplateRef:
    name: agent-template
```

### Sizing Guidelines

| Use Case | Warm Pool Size | Reasoning |
|----------|---------------|-----------|
| Development/testing | 1-2 | Low cost, occasional usage |
| Production (low traffic) | 3-5 | Buffer for burst requests |
| Production (high traffic) | 10+ | Handle concurrent agent requests |

**Cost trade-off**: Each warm pool pod runs on a dedicated node. Cost per node: t3.medium ~$0.04/hr, m5.xlarge ~$0.19/hr. A pool of 5 on m5.xlarge costs ~$0.95/hr idle; on t3.medium only ~$0.20/hr.

### Scaling the Warm Pool

```bash
# Scale up
kubectl patch sandboxwarmpool agent-warm-pool -n default \
  --type merge -p '{"spec":{"replicas":5}}'

# Scale down (excess pods and nodes will be cleaned up)
kubectl patch sandboxwarmpool agent-warm-pool -n default \
  --type merge -p '{"spec":{"replicas":1}}'

# Scale to zero (no idle cost, but cold-start on next claim)
kubectl patch sandboxwarmpool agent-warm-pool -n default \
  --type merge -p '{"spec":{"replicas":0}}'
```

### Backfill Behavior

When a warm pod is claimed:
1. WarmPool controller detects `readyReplicas < spec.replicas`
2. Creates a new pod from the SandboxTemplate
3. Karpenter provisions a new node for the pod (~90s)
4. Pod starts running, warm pool is back to full capacity

---

## Claiming a Sandbox

### Basic Claim

```yaml
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxClaim
metadata:
  name: my-agent-session
  namespace: default
spec:
  sandboxTemplateRef:
    name: agent-template
```

### Claim with Lifecycle Policy

```yaml
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxClaim
metadata:
  name: my-agent-session
  namespace: default
spec:
  sandboxTemplateRef:
    name: agent-template
  lifecycle:
    # "Delete" removes all resources; "Retain" stops but keeps objects
    shutdownPolicy: Delete
    # Optional: auto-expire the sandbox at a specific time
    shutdownTime: "2026-12-31T23:59:59Z"
```

### Lifecycle Policies

| Policy | Behavior |
|--------|----------|
| `shutdownPolicy: Delete` | When claim is deleted, pod and all resources are removed |
| `shutdownPolicy: Retain` | When claim is deleted, resources are stopped but kept |
| `shutdownTime` | Sandbox auto-expires at the specified RFC3339 timestamp |

### Claim via kubectl (imperative)

```bash
# Create a claim
cat <<'EOF' | kubectl apply -f -
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxClaim
metadata:
  name: session-$(date +%s)
  namespace: default
spec:
  sandboxTemplateRef:
    name: agent-template
  lifecycle:
    shutdownPolicy: Delete
EOF

# Check claim status
kubectl get sandboxclaims -n default

# Delete claim (releases sandbox)
kubectl delete sandboxclaim session-123 -n default
```

---

## Monitoring

### Check Warm Pool Status

```bash
# Overview
kubectl get sandboxwarmpools -n default

# Detailed status
kubectl describe sandboxwarmpool agent-warm-pool -n default
```

### Check Active Sandboxes

```bash
# All sandboxes
kubectl get sandboxes -n default

# All claims
kubectl get sandboxclaims -n default

# Pods on Karpenter nodes
kubectl get pods -n default -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase'
```

### Check Karpenter Nodes

```bash
# NodeClaims (Karpenter-managed nodes)
kubectl get nodeclaims

# Node details
kubectl get nodes -l node-type=agent-sandbox -o wide

# Karpenter controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=20
```

### Verify Isolation

```bash
# Confirm 1 user pod per Karpenter node
for NODE in $(kubectl get nodes -l node-type=agent-sandbox --no-headers | awk '{print $1}'); do
  PODS=$(kubectl get pods --all-namespaces --field-selector spec.nodeName=$NODE --no-headers | grep -v kube-system | wc -l)
  echo "$NODE: $PODS user pod(s)"
done

# Confirm no external IPs (private subnets)
kubectl get nodes -l node-type=agent-sandbox \
  -o custom-columns='NAME:.metadata.name,EXT-IP:.status.addresses[?(@.type=="ExternalIP")].address'
```

---

## Advanced Use Cases

### Custom Agent Image

Replace `busybox` with your agent image:

```yaml
containers:
- name: agent
  image: my-registry/my-agent:v1.0
  command: ["/app/agent", "--listen", "0.0.0.0:8080"]
  env:
  - name: AGENT_ID
    valueFrom:
      fieldRef:
        fieldPath: metadata.name
  resources:
    # For m5.xlarge (4 vCPU / 16GB)
    requests: { cpu: "3500m", memory: "12Gi" }
    # For t3.medium (2 vCPU / 4GB), use:
    # requests: { cpu: "1", memory: "2Gi" }
```

### Multiple Template Pools

Run different agent types with separate templates and warm pools:

```yaml
# Template 1: Code interpreter (low-spec, t3.medium)
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxTemplate
metadata:
  name: code-interpreter
spec:
  podTemplate:
    spec:
      tolerations: [...]
      nodeSelector: { node-type: agent-sandbox }
      containers:
      - name: agent
        image: python:3.12-slim
        resources:
          requests: { cpu: "1", memory: "2Gi" }
          limits: { cpu: "1", memory: "2Gi" }
---
# Template 2: Browser agent (standard, m5.xlarge)
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxTemplate
metadata:
  name: browser-agent
spec:
  podTemplate:
    spec:
      tolerations: [...]
      nodeSelector: { node-type: agent-sandbox }
      containers:
      - name: agent
        image: my-chromium-agent:latest
        resources:
          requests: { cpu: "3500m", memory: "12Gi" }
          limits: { cpu: "4", memory: "14Gi" }
---
# Warm pools for each
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxWarmPool
metadata:
  name: code-pool
spec:
  replicas: 3
  sandboxTemplateRef:
    name: code-interpreter
---
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxWarmPool
metadata:
  name: browser-pool
spec:
  replicas: 2
  sandboxTemplateRef:
    name: browser-agent
```

Claim from a specific pool:
```yaml
spec:
  sandboxTemplateRef:
    name: code-interpreter    # or browser-agent
```

### Burst Scaling

For handling spikes, increase warm pool temporarily:

```bash
# Scale up for expected burst
kubectl patch sandboxwarmpool agent-warm-pool -n default \
  --type merge -p '{"spec":{"replicas":10}}'

# Wait for Karpenter to provision nodes (~90s)
watch kubectl get nodeclaims

# After burst, scale back down
kubectl patch sandboxwarmpool agent-warm-pool -n default \
  --type merge -p '{"spec":{"replicas":2}}'
```

### Programmatic Claim (Python SDK)

```bash
pip install k8s-agent-sandbox==0.2.1
```

```python
from agent_sandbox import SandboxClient

client = SandboxClient()

# Claim a sandbox from warm pool
sandbox = client.claim(
    template_name="agent-template",
    namespace="default",
    shutdown_policy="Delete"
)

print(f"Sandbox ready: {sandbox.name}")
print(f"Pod IP: {sandbox.pod_ip}")

# Use the sandbox...

# Release when done
sandbox.release()
```

---

## API Reference

### SandboxTemplate

```yaml
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxTemplate
metadata:
  name: <string>           # Template name (referenced by WarmPool and Claim)
  namespace: <string>      # Must match WarmPool/Claim namespace
spec:
  podTemplate:
    spec: <PodSpec>         # Standard Kubernetes PodSpec
```

### SandboxWarmPool

```yaml
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxWarmPool
metadata:
  name: <string>
  namespace: <string>
spec:
  replicas: <int>                # Number of pre-provisioned sandboxes
  sandboxTemplateRef:
    name: <string>               # Must match SandboxTemplate name
status:
  readyReplicas: <int>          # Number of ready sandboxes
```

### SandboxClaim

```yaml
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxClaim
metadata:
  name: <string>
  namespace: <string>           # Must match SandboxTemplate namespace
spec:
  sandboxTemplateRef:
    name: <string>               # Must match SandboxTemplate name
  lifecycle:
    shutdownPolicy: <Delete|Retain>    # Default: Retain
    shutdownTime: <RFC3339 timestamp>  # Optional auto-expiry
status:
  conditions:
  - type: Ready
    status: <True|False>
    message: <string>
  sandbox:
    Name: <string>               # Bound sandbox name
```

### Sandbox

```yaml
apiVersion: agents.x-k8s.io/v1alpha1
kind: Sandbox
metadata:
  name: <string>
  namespace: <string>
spec:
  podTemplate:
    spec: <PodSpec>
```

---

## Quick Reference Commands

```bash
# List all sandbox resources
kubectl get sandboxtemplates,sandboxwarmpools,sandboxclaims,sandboxes -n default

# Create a claim
kubectl apply -f claim.yaml

# Check claim status
kubectl get sandboxclaim <name> -n default -o jsonpath='{.status.conditions[0].status}'

# Get warm pool ready count
kubectl get sandboxwarmpool <name> -n default -o jsonpath='{.status.readyReplicas}'

# Scale warm pool
kubectl patch sandboxwarmpool <name> -n default --type merge -p '{"spec":{"replicas":N}}'

# Delete a claim
kubectl delete sandboxclaim <name> -n default

# Watch sandbox events
kubectl get events -n default --field-selector reason!=FailedScheduling -w
```
