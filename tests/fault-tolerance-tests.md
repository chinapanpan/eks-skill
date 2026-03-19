# Fault Tolerance Test Suite — Reproduction Guide

Tested on `t3.medium` (2 vCPU / 4GB), warm pool replicas=2, EKS 1.34, Agent Sandbox v0.2.1.

## Prerequisites

Cluster must be fully deployed per `setup_guide.md`. Verify before running:

```bash
# All system components healthy
kubectl get pods -n kube-system | grep -E 'karpenter|load-balancer|ebs'
kubectl get pods -n agent-sandbox-system

# Warm pool ready
kubectl get sandboxwarmpools -n default
# Expected: READY=2

# 2 pods on 2 nodes
kubectl get pods -n default -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase'
kubectl get nodeclaims
```

---

## T1: Warm Pool Pod Deletion Recovery

**Goal**: Verify warm pool auto-replaces a deleted pod.

```bash
# Record current pods
kubectl get pods -n default --no-headers
TARGET_POD=$(kubectl get pods -n default --no-headers -o custom-columns=':.metadata.name' | head -1)
echo "Deleting pod: $TARGET_POD"

# Delete one warm pool pod
kubectl delete pod "$TARGET_POD" -n default

# Watch recovery
for i in $(seq 1 20); do
  READY=$(kubectl get sandboxwarmpools agent-warm-pool -n default \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  PODS=$(kubectl get pods -n default --no-headers 2>/dev/null | grep -c Running)
  echo "  ($i) warmpool ready=$READY, running pods=$PODS"
  if [ "$READY" = "2" ] && [ "$PODS" -ge 2 ]; then
    echo "T1 PASS: Warm pool recovered to 2/2"
    break
  fi
  sleep 5
done

# Verify new pod created
kubectl get pods -n default -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase'
```

**Expected**: New pod created in ~5s, warm pool restored to 2/2 Ready.

---

## T2: EC2 Node Termination Recovery

**Goal**: Verify Karpenter provisions a replacement node after instance termination.

```bash
# Pick a node backing a warm pool pod
TARGET_POD=$(kubectl get pods -n default --no-headers -o custom-columns=':.metadata.name' | head -1)
NODE_NAME=$(kubectl get pod "$TARGET_POD" -n default -o jsonpath='{.spec.nodeName}')
INSTANCE_ID=$(kubectl get node "$NODE_NAME" -o jsonpath='{.spec.providerID}' | sed 's|.*/||')
echo "Terminating instance: $INSTANCE_ID (node: $NODE_NAME)"

# Terminate the EC2 instance
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" \
  --region ${AWS_DEFAULT_REGION} \
  --query 'TerminatingInstances[0].CurrentState.Name' --output text

# Watch recovery
for i in $(seq 1 36); do
  READY=$(kubectl get sandboxwarmpools agent-warm-pool -n default \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  NC=$(kubectl get nodeclaims --no-headers 2>/dev/null | grep -c "True")
  RUNNING=$(kubectl get pods -n default --no-headers 2>/dev/null | grep -c "Running")
  echo "  (${i}0s) warmpool ready=$READY, nodeclaims ready=$NC, pods running=$RUNNING"
  if [ "$READY" = "2" ] && [ "$NC" -ge 2 ] && [ "$RUNNING" -ge 2 ]; then
    echo "T2 PASS: Full recovery after node termination"
    break
  fi
  if [ "$i" -eq 36 ]; then echo "T2 FAIL: Timeout after 180s"; fi
  sleep 5
done

# Final state
kubectl get nodeclaims
kubectl get pods -n default -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase'
```

**Expected**: Karpenter creates new node in ~56s, warm pool recovers to 2/2.

---

## T3: Claim Consumes Pool + Backfill

**Goal**: Verify claim binds from warm pool and pool auto-backfills.

```bash
# Create a SandboxClaim
START=$(date +%s)
cat <<'EOF' | kubectl apply -f -
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxClaim
metadata:
  name: t3-claim-1
  namespace: default
spec:
  sandboxTemplateRef:
    name: agent-template
  lifecycle:
    shutdownPolicy: Delete
EOF

# Watch claim binding
for i in $(seq 1 10); do
  READY=$(kubectl get sandboxclaim t3-claim-1 -n default \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  if [ "$READY" = "True" ]; then
    END=$(date +%s)
    echo "Claim ready in $((END-START))s"
    break
  fi
  echo "  ($i) ready=$READY"
  sleep 2
done

# Watch warm pool backfill
for i in $(seq 1 24); do
  READY=$(kubectl get sandboxwarmpools agent-warm-pool -n default \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  echo "  (${i}0s) warmpool ready=$READY"
  if [ "$READY" = "2" ]; then
    echo "T3 PASS: Claim bound + warm pool backfilled to 2/2"
    break
  fi
  sleep 5
done

# Cleanup
kubectl delete sandboxclaim t3-claim-1 -n default
```

**Expected**: Claim binds instantly (<3s), warm pool backfills in ~10s.

---

## T4: Pool Exhaustion — Cold Start

**Goal**: Exhaust warm pool, then verify a new claim triggers cold start (new node).

```bash
# Create 2 claims to exhaust the pool
cat <<'EOF' | kubectl apply -f -
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxClaim
metadata:
  name: t4-claim-1
  namespace: default
spec:
  sandboxTemplateRef:
    name: agent-template
  lifecycle:
    shutdownPolicy: Delete
---
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxClaim
metadata:
  name: t4-claim-2
  namespace: default
spec:
  sandboxTemplateRef:
    name: agent-template
  lifecycle:
    shutdownPolicy: Delete
EOF

sleep 3
echo "Warm pool after exhaust:"
kubectl get sandboxwarmpools agent-warm-pool -n default

# Create 3rd claim (cold start)
START=$(date +%s)
cat <<'EOF' | kubectl apply -f -
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxClaim
metadata:
  name: t4-claim-3
  namespace: default
spec:
  sandboxTemplateRef:
    name: agent-template
  lifecycle:
    shutdownPolicy: Delete
EOF

echo "Waiting for cold start claim..."
for i in $(seq 1 36); do
  READY=$(kubectl get sandboxclaim t4-claim-3 -n default \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  if [ "$READY" = "True" ]; then
    END=$(date +%s)
    echo "T4 PASS: Cold start claim ready in $((END-START))s"
    break
  fi
  echo "  (${i}0s) claim ready=$READY"
  if [ "$i" -eq 36 ]; then echo "T4 FAIL: Timeout 180s"; fi
  sleep 5
done

# Cleanup
kubectl delete sandboxclaim t4-claim-1 t4-claim-2 t4-claim-3 -n default
```

**Expected**: First 2 claims instant, 3rd claim ~45s (new node provisioned by Karpenter).

---

## T5: Claimed Pod Deletion (Critical Finding)

**Goal**: Verify behavior when a pod backing an active claim is force-deleted.

```bash
# Create a claim
cat <<'EOF' | kubectl apply -f -
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxClaim
metadata:
  name: t5-claim
  namespace: default
spec:
  sandboxTemplateRef:
    name: agent-template
  lifecycle:
    shutdownPolicy: Delete
EOF

sleep 5

# Find the pod backing this claim
SELECTOR=$(kubectl get sandbox t5-claim -n default \
  -o jsonpath='{.status.selector}')
CLAIM_POD=$(kubectl get pods -n default -l "$SELECTOR" \
  --no-headers -o custom-columns=':.metadata.name' | head -1)
echo "Claimed pod: $CLAIM_POD"

# Force-delete the pod
kubectl delete pod "$CLAIM_POD" -n default --grace-period=0 --force

# Watch claim status
for i in $(seq 1 12); do
  CLAIM_READY=$(kubectl get sandboxclaim t5-claim -n default \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  REASON=$(kubectl get sandboxclaim t5-claim -n default \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null)
  echo "  ($i) ready=$CLAIM_READY, reason=$REASON"
  if [ "$REASON" = "ReconcilerError" ]; then
    echo "T5 CONFIRMED: Claim stuck in Ready=False with ReconcilerError"
    break
  fi
  sleep 5
done

# Show error detail
kubectl get sandboxclaim t5-claim -n default \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}'
echo ""

# Cleanup
kubectl delete sandboxclaim t5-claim -n default
```

**Expected**: Claim enters `Ready=False` with `ReconcilerError: Pod "xxx" not found`. Does NOT auto-recover. This is a known limitation — application-layer retry is required.

---

## T6: Burst Claims + Release

**Goal**: Verify pool recovers after burst claim creation and rapid release.

```bash
# Create 3 claims simultaneously
cat <<'EOF' | kubectl apply -f -
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxClaim
metadata:
  name: t6-claim-1
  namespace: default
spec:
  sandboxTemplateRef:
    name: agent-template
  lifecycle:
    shutdownPolicy: Delete
---
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxClaim
metadata:
  name: t6-claim-2
  namespace: default
spec:
  sandboxTemplateRef:
    name: agent-template
  lifecycle:
    shutdownPolicy: Delete
---
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxClaim
metadata:
  name: t6-claim-3
  namespace: default
spec:
  sandboxTemplateRef:
    name: agent-template
  lifecycle:
    shutdownPolicy: Delete
EOF

sleep 5
echo "Claims created:"
kubectl get sandboxclaims -n default
echo "Total pods:"
kubectl get pods -n default --no-headers | wc -l

# Delete all claims
kubectl delete sandboxclaim t6-claim-1 t6-claim-2 t6-claim-3 -n default

# Watch pool recovery
for i in $(seq 1 30); do
  READY=$(kubectl get sandboxwarmpools agent-warm-pool -n default \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  PODS=$(kubectl get pods -n default --no-headers 2>/dev/null | grep -c "Running")
  echo "  (${i}0s) warmpool ready=$READY, running pods=$PODS"
  if [ "$READY" = "2" ] && [ "$PODS" -le 3 ]; then
    echo "T6 PASS: All claims released, warm pool stabilized at $READY ready"
    break
  fi
  if [ "$i" -eq 30 ]; then echo "T6 FAIL: Timeout"; fi
  sleep 5
done

# Final state
kubectl get sandboxclaims -n default
kubectl get pods -n default -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase'
```

**Expected**: All claims released, warm pool recovers to 2/2 in ~25s, excess nodes consolidated.

---

## T7: EBS Volume Mount (5Gi gp3)

**Goal**: Verify EBS ephemeral volume works with SandboxTemplate — provisioning, read/write, claim binding, and cleanup.

### Setup: gp3 StorageClass

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
allowVolumeExpansion: true
EOF
```

### Setup: SandboxTemplate with EBS

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxTemplate
metadata:
  name: agent-template-ebs
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
                agents.x-k8s.io/sandbox-template: agent-template-ebs
            topologyKey: kubernetes.io/hostname
      securityContext:
        runAsUser: 1000
        runAsGroup: 3000
        fsGroup: 2000
        runAsNonRoot: true
      containers:
      - name: agent
        image: busybox
        command: ["/bin/sh", "-c", "echo 'Agent with EBS running'; sleep 36000"]
        resources:
          requests:
            cpu: "1"
            memory: "2Gi"
          limits:
            cpu: "1"
            memory: "2Gi"
        volumeMounts:
        - name: data
          mountPath: /data
      volumes:
      - name: data
        ephemeral:
          volumeClaimTemplate:
            spec:
              accessModes: ["ReadWriteOnce"]
              storageClassName: gp3
              resources:
                requests:
                  storage: 5Gi
EOF
```

### Test: Warm Pool with EBS

```bash
# Create warm pool
cat <<'EOF' | kubectl apply -f -
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxWarmPool
metadata:
  name: ebs-warm-pool
  namespace: default
spec:
  replicas: 1
  sandboxTemplateRef:
    name: agent-template-ebs
EOF

# Wait for ready
for i in $(seq 1 36); do
  READY=$(kubectl get sandboxwarmpools ebs-warm-pool -n default \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  echo "  (${i}0s) warmpool ready=$READY"
  if [ "$READY" = "1" ]; then
    echo "EBS warm pool ready!"
    break
  fi
  sleep 5
done

# Verify EBS mount
EBS_POD=$(kubectl get pods -n default --no-headers | grep ebs-warm | awk '{print $1}')
echo "=== PVC ==="
kubectl get pvc -n default
echo "=== Mount ==="
kubectl exec "$EBS_POD" -n default -- df -h /data
echo "=== Write test ==="
kubectl exec "$EBS_POD" -n default -- sh -c \
  "echo 'hello from EBS' > /data/test.txt && cat /data/test.txt && ls -la /data/"
```

**Expected**: Pod ready in ~55s, PVC Bound 5Gi gp3, read/write works at `/data`.

### Test: Claim with EBS

```bash
START=$(date +%s)
cat <<'EOF' | kubectl apply -f -
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxClaim
metadata:
  name: t7-ebs-claim
  namespace: default
spec:
  sandboxTemplateRef:
    name: agent-template-ebs
  lifecycle:
    shutdownPolicy: Delete
EOF

for i in $(seq 1 20); do
  READY=$(kubectl get sandboxclaim t7-ebs-claim -n default \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  if [ "$READY" = "True" ]; then
    END=$(date +%s)
    echo "Claim ready in $((END-START))s"
    break
  fi
  echo "  ($i) ready=$READY"
  sleep 3
done

# Verify EBS in claimed sandbox
SELECTOR=$(kubectl get sandbox t7-ebs-claim -n default \
  -o jsonpath='{.status.selector}')
CLAIM_POD=$(kubectl get pods -n default -l "$SELECTOR" \
  --no-headers -o custom-columns=':.metadata.name' | head -1)
kubectl exec "$CLAIM_POD" -n default -- sh -c \
  "df -h /data && echo 'claim write' > /data/claim.txt && cat /data/claim.txt"
```

**Expected**: Claim binds in ~3s from warm pool, EBS readable/writable.

### Test: Cleanup Lifecycle

```bash
# Delete claim
kubectl delete sandboxclaim t7-ebs-claim -n default
sleep 10

# Verify PVC/PV auto-deleted (ephemeral volume lifecycle)
echo "PVCs remaining:"
kubectl get pvc -n default

# Wait for warm pool backfill with fresh EBS
for i in $(seq 1 24); do
  READY=$(kubectl get sandboxwarmpools ebs-warm-pool -n default \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  echo "  (${i}0s) warmpool ready=$READY"
  if [ "$READY" = "1" ]; then
    echo "T7 PASS: EBS warm pool backfilled"
    break
  fi
  sleep 5
done

# Full cleanup
kubectl delete sandboxwarmpool ebs-warm-pool -n default
kubectl delete sandboxtemplate agent-template-ebs -n default
sleep 15
kubectl delete pvc -n default --all 2>/dev/null
echo "Cleanup complete"
```

**Expected**: PVC auto-deleted on claim release. Warm pool backfills with fresh EBS in ~35s.

### Data Persistence Limitation

This test uses **Generic Ephemeral Volumes** — PVC lifecycle is tied to the Pod. If the pod is deleted, the PVC and data are also deleted. This is different from `Sandbox.spec.volumeClaimTemplates` (see [issue #225](https://github.com/kubernetes-sigs/agent-sandbox/issues/225)), which would retain PVCs across pod recreations but is not yet supported in SandboxTemplate.

---

## Results Summary

| # | Test | Result | Recovery Time |
|---|------|--------|---------------|
| T1 | Warm Pool Pod Deletion | **PASS** | ~5s |
| T2 | EC2 Node Termination | **PASS** | ~56s |
| T3 | Claim + Backfill | **PASS** | ~10s backfill |
| T4 | Pool Exhaustion Cold Start | **PASS** | ~45s |
| T5 | Claimed Pod Deletion | **WARN** | No auto-recovery |
| T6 | Burst Claims + Release | **PASS** | ~25s |
| T7 | EBS Volume Mount | **PASS** | ~55s initial, ~35s backfill |

### Key Findings

1. **Warm pool is self-healing** — pod deletion, node failure, and burst usage all recover automatically.
2. **Active Claims do NOT self-heal** — if the backing pod is lost, the Claim stays `Ready=False`. Application-layer retry (delete + re-claim) is required.
3. **Ephemeral EBS data is NOT persistent** — pod deletion = data loss. Use only for scratch/cache data. For persistent data, back up to S3 or wait for `volumeClaimTemplates` support ([#225](https://github.com/kubernetes-sigs/agent-sandbox/issues/225)).
