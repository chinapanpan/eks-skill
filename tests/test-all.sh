#!/bin/bash
set -euo pipefail

#############################################
# EKS + Karpenter + ALB + Agent Sandbox
# Comprehensive Test Suite
#############################################

REGION="${TEST_REGION:-ap-northeast-1}"
CLUSTER_NAME="${TEST_CLUSTER_NAME:-agent-sandbox-cluster}"
NAMESPACE="default"
TEST_NS="test-validation"
PASS=0
FAIL=0
TOTAL=0

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_test() {
  TOTAL=$((TOTAL + 1))
  echo ""
  echo -e "${YELLOW}[TEST $TOTAL] $1${NC}"
}

log_pass() {
  PASS=$((PASS + 1))
  echo -e "${GREEN}  [PASS] $1${NC}"
}

log_fail() {
  FAIL=$((FAIL + 1))
  echo -e "${RED}  [FAIL] $1${NC}"
}

cleanup() {
  echo ""
  echo "============================================"
  echo "  Cleaning up test resources..."
  echo "============================================"
  kubectl delete namespace ${TEST_NS} --ignore-not-found --timeout=120s 2>/dev/null || true
  kubectl delete sandboxclaim -n ${NAMESPACE} -l test-suite=validation --timeout=60s 2>/dev/null || true
  kubectl delete deployment scale-test -n ${NAMESPACE} --ignore-not-found 2>/dev/null || true
  echo "Cleanup done."
}

trap cleanup EXIT

echo "============================================"
echo "  EKS Cluster Validation Test Suite"
echo "  Cluster: ${CLUSTER_NAME}"
echo "  Region:  ${REGION}"
echo "  Time:    $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"

# Create test namespace
kubectl create namespace ${TEST_NS} --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1

########################################
# TEST GROUP 1: Karpenter Autoscaling
########################################
echo ""
echo "============================================"
echo "  GROUP 1: Karpenter Autoscaling"
echo "============================================"

# --- Test 1.1: Scale-Out ---
log_test "Karpenter Scale-Out: Deploy 3 new sandbox pods -> 3 new nodes"

INITIAL_NODES=$(kubectl get nodeclaims --no-headers 2>/dev/null | wc -l)
echo "  Initial Karpenter NodeClaims: ${INITIAL_NODES}"

# Create 3 pods that require agent-sandbox nodes
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: scale-test
  namespace: ${NAMESPACE}
spec:
  replicas: 3
  selector:
    matchLabels:
      app: scale-test
  template:
    metadata:
      labels:
        app: scale-test
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
                app: scale-test
            topologyKey: kubernetes.io/hostname
      containers:
      - name: worker
        image: busybox
        command: ["/bin/sh", "-c", "sleep 3600"]
        resources:
          requests:
            cpu: "3500m"
            memory: "12Gi"
          limits:
            cpu: "4"
            memory: "14Gi"
EOF

echo "  Waiting for Karpenter to provision new nodes (max 180s)..."
DEADLINE=$(($(date +%s) + 180))
while true; do
  CURRENT_CLAIMS=$(kubectl get nodeclaims --no-headers 2>/dev/null | wc -l)
  EXPECTED=$((INITIAL_NODES + 3))
  if [ "$CURRENT_CLAIMS" -ge "$EXPECTED" ]; then
    break
  fi
  if [ "$(date +%s)" -gt "$DEADLINE" ]; then
    log_fail "Timeout: only ${CURRENT_CLAIMS} NodeClaims (expected ${EXPECTED})"
    break
  fi
  sleep 10
done

FINAL_CLAIMS=$(kubectl get nodeclaims --no-headers 2>/dev/null | wc -l)
EXPECTED=$((INITIAL_NODES + 3))
if [ "$FINAL_CLAIMS" -ge "$EXPECTED" ]; then
  log_pass "Scaled from ${INITIAL_NODES} to ${FINAL_CLAIMS} NodeClaims"
else
  log_fail "Expected >= ${EXPECTED} NodeClaims, got ${FINAL_CLAIMS}"
fi

# Wait for nodes to be ready
echo "  Waiting for new nodes to become Ready (max 120s)..."
DEADLINE=$(($(date +%s) + 120))
while true; do
  READY_NODES=$(kubectl get nodes -l node-type=agent-sandbox --no-headers 2>/dev/null | grep -c " Ready " || true)
  if [ "$READY_NODES" -ge "$EXPECTED" ]; then
    break
  fi
  if [ "$(date +%s)" -gt "$DEADLINE" ]; then
    break
  fi
  sleep 10
done

# --- Test 1.2: Single Pod Per Node ---
log_test "Karpenter: Verify single pod per Karpenter node"

kubectl get nodes -l node-type=agent-sandbox --no-headers 2>/dev/null | while read -r line; do
  NODE_NAME=$(echo "$line" | awk '{print $1}')
  POD_COUNT=$(kubectl get pods --all-namespaces --field-selector "spec.nodeName=${NODE_NAME}" --no-headers 2>/dev/null | grep -v -E 'kube-system|agent-sandbox-system' | wc -l)
  if [ "$POD_COUNT" -le 1 ]; then
    echo -e "  ${GREEN}  Node ${NODE_NAME}: ${POD_COUNT} user pod(s)${NC}"
  else
    echo -e "  ${RED}  Node ${NODE_NAME}: ${POD_COUNT} user pod(s) (VIOLATION!)${NC}"
  fi
done

ALL_KARPENTER_NODES=$(kubectl get nodes -l node-type=agent-sandbox --no-headers 2>/dev/null | wc -l)
VIOLATION=0
for NODE_NAME in $(kubectl get nodes -l node-type=agent-sandbox --no-headers 2>/dev/null | awk '{print $1}'); do
  POD_COUNT=$(kubectl get pods --all-namespaces --field-selector "spec.nodeName=${NODE_NAME}" --no-headers 2>/dev/null | grep -v -E 'kube-system|agent-sandbox-system' | wc -l)
  if [ "$POD_COUNT" -gt 1 ]; then
    VIOLATION=$((VIOLATION + 1))
  fi
done
if [ "$VIOLATION" -eq 0 ]; then
  log_pass "All ${ALL_KARPENTER_NODES} Karpenter nodes have at most 1 user pod"
else
  log_fail "${VIOLATION} nodes have more than 1 user pod"
fi

# --- Test 1.3: Private Subnet ---
log_test "Karpenter: All nodes in private subnets (no external IP)"

HAS_EXT=0
for NODE_NAME in $(kubectl get nodes -l node-type=agent-sandbox --no-headers 2>/dev/null | awk '{print $1}'); do
  EXT_IP=$(kubectl get node "${NODE_NAME}" -o jsonpath='{.status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null)
  if [ -n "${EXT_IP}" ]; then
    HAS_EXT=$((HAS_EXT + 1))
    echo "  Node ${NODE_NAME} has external IP: ${EXT_IP}"
  fi
done
if [ "$HAS_EXT" -eq 0 ]; then
  log_pass "All Karpenter nodes have no external IP (private subnets)"
else
  log_fail "${HAS_EXT} nodes have external IPs"
fi

# --- Test 1.4: Node Taints ---
log_test "Karpenter: All nodes have agent-sandbox taint"

UNTAINTED=0
for NODE_NAME in $(kubectl get nodes -l node-type=agent-sandbox --no-headers 2>/dev/null | awk '{print $1}'); do
  TAINT=$(kubectl get node "${NODE_NAME}" -o jsonpath='{.spec.taints}' 2>/dev/null)
  if ! echo "$TAINT" | grep -q "agent-sandbox"; then
    UNTAINTED=$((UNTAINTED + 1))
  fi
done
if [ "$UNTAINTED" -eq 0 ]; then
  log_pass "All Karpenter nodes have agent-sandbox taint"
else
  log_fail "${UNTAINTED} nodes missing agent-sandbox taint"
fi

# --- Test 1.5: Scale-In ---
log_test "Karpenter Scale-In: Delete scale-test deployment -> nodes consolidated"

PRE_DELETE_CLAIMS=$(kubectl get nodeclaims --no-headers 2>/dev/null | wc -l)
kubectl delete deployment scale-test -n ${NAMESPACE} --ignore-not-found > /dev/null 2>&1

echo "  Pre-delete NodeClaims: ${PRE_DELETE_CLAIMS}"
echo "  Waiting for Karpenter WhenEmpty consolidation (max 180s)..."
DEADLINE=$(($(date +%s) + 180))
while true; do
  CURRENT_CLAIMS=$(kubectl get nodeclaims --no-headers 2>/dev/null | wc -l)
  # Should scale back to just the warm pool nodes
  if [ "$CURRENT_CLAIMS" -le "$INITIAL_NODES" ]; then
    break
  fi
  if [ "$(date +%s)" -gt "$DEADLINE" ]; then
    break
  fi
  sleep 15
done

POST_DELETE_CLAIMS=$(kubectl get nodeclaims --no-headers 2>/dev/null | wc -l)
if [ "$POST_DELETE_CLAIMS" -lt "$PRE_DELETE_CLAIMS" ]; then
  log_pass "Scaled in from ${PRE_DELETE_CLAIMS} to ${POST_DELETE_CLAIMS} NodeClaims"
else
  log_fail "Expected fewer NodeClaims after scale-in, got ${POST_DELETE_CLAIMS}"
fi

########################################
# TEST GROUP 2: ALB Controller
########################################
echo ""
echo "============================================"
echo "  GROUP 2: ALB Controller"
echo "============================================"

# --- Test 2.1: ALB Controller Running ---
log_test "ALB Controller: Deployment healthy"

ALB_READY=$(kubectl get deployment aws-load-balancer-controller -n kube-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
ALB_DESIRED=$(kubectl get deployment aws-load-balancer-controller -n kube-system -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
if [ "$ALB_READY" -eq "$ALB_DESIRED" ] && [ "$ALB_READY" -gt 0 ]; then
  log_pass "ALB Controller ready: ${ALB_READY}/${ALB_DESIRED} replicas"
else
  log_fail "ALB Controller not healthy: ${ALB_READY}/${ALB_DESIRED} replicas"
fi

# --- Test 2.2: ALB IngressClass ---
log_test "ALB Controller: IngressClass 'alb' exists"

if kubectl get ingressclass alb > /dev/null 2>&1; then
  log_pass "IngressClass 'alb' registered"
else
  log_fail "IngressClass 'alb' not found"
fi

# --- Test 2.3: ALB Ingress End-to-End ---
log_test "ALB Controller: Create Ingress -> ALB provisioned"

# Deploy a simple nginx service in test namespace
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-alb-test
  namespace: ${TEST_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-alb-test
  template:
    metadata:
      labels:
        app: nginx-alb-test
    spec:
      containers:
      - name: nginx
        image: public.ecr.aws/nginx/nginx:1.27
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-alb-test
  namespace: ${TEST_NS}
spec:
  type: NodePort
  selector:
    app: nginx-alb-test
  ports:
  - port: 80
    targetPort: 80
    protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx-alb-test
  namespace: ${TEST_NS}
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
spec:
  ingressClassName: alb
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: nginx-alb-test
            port:
              number: 80
EOF

echo "  Waiting for ALB to be provisioned (max 180s)..."
DEADLINE=$(($(date +%s) + 180))
ALB_ADDRESS=""
while true; do
  ALB_ADDRESS=$(kubectl get ingress nginx-alb-test -n ${TEST_NS} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [ -n "$ALB_ADDRESS" ]; then
    break
  fi
  if [ "$(date +%s)" -gt "$DEADLINE" ]; then
    break
  fi
  sleep 10
done

if [ -n "$ALB_ADDRESS" ]; then
  log_pass "ALB provisioned: ${ALB_ADDRESS}"

  # Test 2.4: HTTP response
  log_test "ALB Controller: HTTP response from ALB endpoint"
  echo "  Waiting 30s for ALB targets to register..."
  sleep 30
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 15 "http://${ALB_ADDRESS}/" 2>/dev/null || echo "000")
  if [ "$HTTP_CODE" -eq 200 ] || [ "$HTTP_CODE" -eq 301 ] || [ "$HTTP_CODE" -eq 302 ]; then
    log_pass "ALB returned HTTP ${HTTP_CODE}"
  elif [ "$HTTP_CODE" -eq 503 ]; then
    echo "  ALB returned 503 (targets may still be registering, retrying in 30s...)"
    sleep 30
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 15 "http://${ALB_ADDRESS}/" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" -eq 200 ]; then
      log_pass "ALB returned HTTP ${HTTP_CODE} (after retry)"
    else
      log_fail "ALB returned HTTP ${HTTP_CODE} after retry"
    fi
  else
    log_fail "ALB returned HTTP ${HTTP_CODE}"
  fi
else
  log_fail "ALB not provisioned within timeout"
  # Skip HTTP test
  log_test "ALB Controller: HTTP response (SKIPPED - no ALB)"
  log_fail "Skipped due to no ALB address"
fi

########################################
# TEST GROUP 3: Agent Sandbox
########################################
echo ""
echo "============================================"
echo "  GROUP 3: Agent Sandbox (Warm Pool + Claim)"
echo "============================================"

# --- Test 3.1: Controller Running ---
log_test "Agent Sandbox: Controller healthy"

AS_READY=$(kubectl get deployment agent-sandbox-controller -n agent-sandbox-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [ "$AS_READY" -gt 0 ]; then
  log_pass "Agent Sandbox Controller ready: ${AS_READY} replica(s)"
else
  log_fail "Agent Sandbox Controller not ready"
fi

# --- Test 3.2: Warm Pool Ready ---
log_test "Agent Sandbox: Warm pool is fully ready"

# Wait for warm pool to stabilize after scale-in tests
echo "  Waiting 30s for warm pool to stabilize..."
sleep 30
WP_READY=$(kubectl get sandboxwarmpool agent-warm-pool -n ${NAMESPACE} -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
WP_DESIRED=$(kubectl get sandboxwarmpool agent-warm-pool -n ${NAMESPACE} -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
if [ "$WP_READY" -eq "$WP_DESIRED" ] && [ "$WP_READY" -gt 0 ]; then
  log_pass "Warm pool ready: ${WP_READY}/${WP_DESIRED}"
else
  echo "  Warm pool not yet ready (${WP_READY}/${WP_DESIRED}), waiting 90s more..."
  sleep 90
  WP_READY=$(kubectl get sandboxwarmpool agent-warm-pool -n ${NAMESPACE} -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [ "$WP_READY" -eq "$WP_DESIRED" ] && [ "$WP_READY" -gt 0 ]; then
    log_pass "Warm pool ready: ${WP_READY}/${WP_DESIRED} (after wait)"
  else
    log_fail "Warm pool not ready: ${WP_READY}/${WP_DESIRED}"
  fi
fi

# --- Test 3.3: Single Claim Latency ---
log_test "Agent Sandbox: Single SandboxClaim latency from warm pool"

WP_BEFORE=$(kubectl get sandboxwarmpool agent-warm-pool -n ${NAMESPACE} -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
START_MS=$(date +%s%3N)

cat <<EOF | kubectl apply -f -
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxClaim
metadata:
  name: latency-test-1
  namespace: ${NAMESPACE}
  labels:
    test-suite: validation
spec:
  sandboxTemplateRef:
    name: agent-template
  lifecycle:
    shutdownPolicy: Delete
EOF

# Poll for Ready status
DEADLINE=$(($(date +%s) + 30))
CLAIM_READY="False"
while true; do
  CLAIM_READY=$(kubectl get sandboxclaim latency-test-1 -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
  if [ "$CLAIM_READY" = "True" ]; then
    break
  fi
  if [ "$(date +%s)" -gt "$DEADLINE" ]; then
    break
  fi
  sleep 0.5
done

END_MS=$(date +%s%3N)
LATENCY=$((END_MS - START_MS))

if [ "$CLAIM_READY" = "True" ]; then
  log_pass "SandboxClaim bound in ${LATENCY}ms (Ready=True)"
else
  log_fail "SandboxClaim not ready within 30s"
fi

WP_AFTER=$(kubectl get sandboxwarmpool agent-warm-pool -n ${NAMESPACE} -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
echo "  Warm pool: ${WP_BEFORE} -> ${WP_AFTER} ready replicas"

# --- Test 3.4: Warm Pool Backfill ---
log_test "Agent Sandbox: Warm pool backfills after claim"

echo "  Waiting for warm pool to backfill (max 180s)..."
DEADLINE=$(($(date +%s) + 180))
while true; do
  WP_CURRENT=$(kubectl get sandboxwarmpool agent-warm-pool -n ${NAMESPACE} -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [ "$WP_CURRENT" -ge "$WP_DESIRED" ]; then
    break
  fi
  if [ "$(date +%s)" -gt "$DEADLINE" ]; then
    break
  fi
  sleep 10
done

WP_FINAL=$(kubectl get sandboxwarmpool agent-warm-pool -n ${NAMESPACE} -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [ "$WP_FINAL" -ge "$WP_DESIRED" ]; then
  log_pass "Warm pool backfilled to ${WP_FINAL}/${WP_DESIRED}"
else
  log_fail "Warm pool only at ${WP_FINAL}/${WP_DESIRED} after backfill wait"
fi

# --- Test 3.5: Burst Claims ---
log_test "Agent Sandbox: Burst 2 SandboxClaims simultaneously"

# Ensure warm pool is full first
WP_READY_NOW=$(kubectl get sandboxwarmpool agent-warm-pool -n ${NAMESPACE} -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
echo "  Warm pool ready before burst: ${WP_READY_NOW}"

START_MS=$(date +%s%3N)
cat <<EOF | kubectl apply -f -
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxClaim
metadata:
  name: burst-claim-1
  namespace: ${NAMESPACE}
  labels:
    test-suite: validation
spec:
  sandboxTemplateRef:
    name: agent-template
  lifecycle:
    shutdownPolicy: Delete
---
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxClaim
metadata:
  name: burst-claim-2
  namespace: ${NAMESPACE}
  labels:
    test-suite: validation
spec:
  sandboxTemplateRef:
    name: agent-template
  lifecycle:
    shutdownPolicy: Delete
EOF

# Wait for both to be ready
DEADLINE=$(($(date +%s) + 30))
READY_COUNT=0
while true; do
  R1=$(kubectl get sandboxclaim burst-claim-1 -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
  R2=$(kubectl get sandboxclaim burst-claim-2 -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
  READY_COUNT=0
  [ "$R1" = "True" ] && READY_COUNT=$((READY_COUNT + 1))
  [ "$R2" = "True" ] && READY_COUNT=$((READY_COUNT + 1))
  if [ "$READY_COUNT" -ge 2 ]; then
    break
  fi
  if [ "$(date +%s)" -gt "$DEADLINE" ]; then
    break
  fi
  sleep 0.5
done
END_MS=$(date +%s%3N)
BURST_LATENCY=$((END_MS - START_MS))

if [ "$READY_COUNT" -ge 2 ]; then
  log_pass "Both burst claims ready in ${BURST_LATENCY}ms"
else
  log_fail "Only ${READY_COUNT}/2 burst claims ready within 30s"
fi

# --- Test 3.6: Claim Cleanup ---
log_test "Agent Sandbox: Claim deletion releases sandbox"

PRE_SANDBOXES=$(kubectl get sandboxes -n ${NAMESPACE} --no-headers 2>/dev/null | wc -l)
kubectl delete sandboxclaim -n ${NAMESPACE} -l test-suite=validation > /dev/null 2>&1
sleep 5
POST_SANDBOXES=$(kubectl get sandboxes -n ${NAMESPACE} --no-headers 2>/dev/null | wc -l)

if [ "$POST_SANDBOXES" -lt "$PRE_SANDBOXES" ]; then
  log_pass "Sandboxes released: ${PRE_SANDBOXES} -> ${POST_SANDBOXES}"
else
  log_fail "Sandboxes not released: ${PRE_SANDBOXES} -> ${POST_SANDBOXES}"
fi

########################################
# SUMMARY
########################################
echo ""
echo "============================================"
echo "  TEST RESULTS SUMMARY"
echo "============================================"
echo -e "  Total:  ${TOTAL}"
echo -e "  ${GREEN}Passed: ${PASS}${NC}"
echo -e "  ${RED}Failed: ${FAIL}${NC}"
echo "============================================"
if [ "$FAIL" -eq 0 ]; then
  echo -e "  ${GREEN}ALL TESTS PASSED${NC}"
else
  echo -e "  ${RED}${FAIL} TEST(S) FAILED${NC}"
fi
echo "============================================"

exit $FAIL
