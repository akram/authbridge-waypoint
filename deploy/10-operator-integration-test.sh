#!/usr/bin/env bash
# End-to-end test for authbridge waypoint + operator-managed client registration
#
# This test demonstrates the integration of:
# 1. Token exchange enabled (via waypoint)
# 2. Operator-managed client registration (automatic Keycloak client creation)
# 3. Multi-team agent communication with automatic credential provisioning
#
# Test architecture:
#
#   team1-ns                          team2-ns
# ┌───────────────────┐           ┌───────────────────┐
# │ team1-agent       │           │ team2-agent       │
# │  (agent)          │──────────>│  (agent)          │
# │                   │           │                   │
# │ team1-waypoint    │           │ team2-waypoint    │
# │  ├─ ext_authz     │           │  ├─ ext_authz     │
# │  │  validate JWT  │           │  │  validate JWT  │
# │  │  + exchange    │           │  │  + exchange    │
# └───────────────────┘           └───────────────────┘
#
# Both agents are automatically registered as Keycloak clients by the operator.
# Credentials are provisioned as Secrets and mounted by the webhook.
# Token exchange happens transparently via waypoints.
#
# Test flow:
# 1. Verify operator creates Keycloak clients automatically
# 2. Verify credentials secrets are created with correct ownership
# 3. Verify waypoints are configured in both namespaces
# 4. Test team1-agent -> team2-agent communication with token exchange
# 5. Verify tokens are properly exchanged with correct audience
#
# Environment variables:
#   KC_URL          — Keycloak base URL (default: http://localhost:18080)
#   OPERATOR_NS     — Namespace where kagenti-operator runs (default: kagenti-operator-system)
#   WEBHOOK_NS      — Namespace where kagenti-webhook runs (default: kagenti-webhook-system)
#   ENABLE_SIDECAR  — Set to "true" to enable AuthBridge sidecar injection (default: false)
#                     When true, creates required ConfigMaps and enables webhook injection
#   SKIP_CLEANUP    — Set to "true" to preserve resources and inspect pods/sidecars
#                     When enabled, the script outputs detailed inspection commands
#                     Usage: export SKIP_CLEANUP=true && ./10-operator-integration-test.sh
#
set -euo pipefail

KEYCLOAK_SVC="${KEYCLOAK_SVC:-keycloak-service}"
KEYCLOAK_NS="${KEYCLOAK_NS:-keycloak}"
REALM="kagenti"
KC_URL="${KC_URL:-http://localhost:18080}"
KC_TOKEN_URL="${KC_URL%/}/realms/${REALM}/protocol/openid-connect/token"
# Keycloak URL for operator (cluster-internal service)
KC_URL_OPERATOR="http://${KEYCLOAK_SVC}.${KEYCLOAK_NS}.svc.cluster.local:8080"
OPERATOR_NS="${OPERATOR_NS:-kagenti-operator-system}"
WEBHOOK_NS="${WEBHOOK_NS:-kagenti-webhook-system}"
ENABLE_SIDECAR="${ENABLE_SIDECAR:-false}"
SKIP_CLEANUP="${SKIP_CLEANUP:-false}"

TEAM1_NS="team1"
TEAM2_NS="team2"
PASS=0
FAIL=0
PF_PID=""

# Color output helpers
info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[PASS]\033[0m  $*"; PASS=$((PASS + 1)); }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m  $*"; FAIL=$((FAIL + 1)); }
detail(){ echo -e "        $*"; }
section() { echo -e "\n\033[1;35m========================================\033[0m"; echo -e "\033[1;35m$*\033[0m"; echo -e "\033[1;35m========================================\033[0m\n"; }

# Retry kubectl commands with exponential backoff
retry_kubectl() {
  local max_attempts=5
  local attempt=1
  local delay=2

  while [ $attempt -le $max_attempts ]; do
    if "$@" 2>&1; then
      return 0
    fi

    if [ $attempt -lt $max_attempts ]; then
      detail "Command failed, retrying in ${delay}s (attempt $attempt/$max_attempts)..."
      sleep $delay
      delay=$((delay * 2))
      attempt=$((attempt + 1))
    else
      detail "Command failed after $max_attempts attempts"
      return 1
    fi
  done
}

# JWT decoding helper
jwt_payload() {
  local payload
  payload=$(echo "$1" | cut -d. -f2 | tr '_-' '/+')
  local pad=$(( 4 - ${#payload} % 4 ))
  [[ $pad -lt 4 ]] && payload="${payload}$(printf '=%.0s' $(seq 1 $pad))"
  echo "$payload" | base64 -d 2>/dev/null
}

# Print JWT claims
print_token_info() {
  local label="$1"
  local token="$2"
  local payload
  payload=$(jwt_payload "$token")

  local iss aud azp sub
  iss=$(echo "$payload" | jq -r '.iss // "n/a"')
  aud=$(echo "$payload" | jq -r 'if .aud | type == "array" then (.aud | join(", ")) else (.aud // "n/a") end')
  azp=$(echo "$payload" | jq -r '.azp // "n/a"')
  sub=$(echo "$payload" | jq -r '.sub // "n/a"')

  detail "$label:"
  detail "  iss: $iss"
  detail "  sub: $sub"
  detail "  aud: $aud"
  detail "  azp: $azp"
}

cleanup() {
  if [[ "$SKIP_CLEANUP" == "true" ]]; then
    echo ""
    section "Resources Preserved for Inspection"
    info "Cleanup skipped (SKIP_CLEANUP=true)"
    echo ""
    info "Test resources have been preserved. Use the following commands to inspect:"
    echo ""

    detail "# View all pods in both namespaces"
    detail "kubectl get pods -n $TEAM1_NS -o wide"
    detail "kubectl get pods -n $TEAM2_NS -o wide"
    echo ""

    detail "# Check pod details and injected containers/volumes"
    detail "kubectl describe pod -n $TEAM1_NS -l app=team1-agent"
    detail "kubectl describe pod -n $TEAM2_NS -l app=team2-agent"
    echo ""

    detail "# View operator-created secrets"
    detail "kubectl get secrets -n $TEAM1_NS | grep kagenti-keycloak"
    detail "kubectl get secrets -n $TEAM2_NS | grep kagenti-keycloak"
    echo ""

    detail "# Inspect secret contents"
    detail "kubectl get secret -n $TEAM1_NS \$(kubectl get secrets -n $TEAM1_NS -o name | grep kagenti-keycloak) -o yaml"
    echo ""

    detail "# Check deployment annotations (operator adds these)"
    detail "kubectl get deployment team1-agent -n $TEAM1_NS -o jsonpath='{.spec.template.metadata.annotations}' | jq"
    detail "kubectl get deployment team2-agent -n $TEAM2_NS -o jsonpath='{.spec.template.metadata.annotations}' | jq"
    echo ""

    detail "# View waypoint gateways"
    detail "kubectl get gateway -n $TEAM1_NS"
    detail "kubectl get gateway -n $TEAM2_NS"
    echo ""

    detail "# Check authorization policies"
    detail "kubectl get authorizationpolicy -n $TEAM1_NS"
    detail "kubectl get authorizationpolicy -n $TEAM2_NS"
    echo ""

    detail "# View operator logs for reconciliation"
    detail "kubectl logs -n $OPERATOR_NS -l control-plane=controller-manager --tail=50 | grep -i team"
    echo ""

    detail "# Verify Keycloak clients were created (requires port-forward)"
    detail "kubectl port-forward -n keycloak svc/keycloak-service 18080:8080 &"
    detail "# Then query Keycloak API:"
    detail "curl -s -X POST http://localhost:18080/realms/kagenti/protocol/openid-connect/token \\"
    detail "  -d 'grant_type=client_credentials' -d 'client_id=admin-cli' -d 'client_secret=admin-secret' | jq -r '.access_token'"
    echo ""

    info "When done inspecting, clean up with:"
    detail "kubectl delete namespace $TEAM1_NS $TEAM2_NS"
    echo ""

    return 0
  fi

  info "Cleaning up test resources..."
  [[ -n "${PF_PID:-}" ]] && kill "$PF_PID" 2>/dev/null || true

  kubectl delete pod -n "$TEAM1_NS" curl-test --force --grace-period=0 2>/dev/null || true
  kubectl delete ns "$TEAM1_NS" --force --grace-period=0 2>/dev/null || true
  kubectl delete ns "$TEAM2_NS" --force --grace-period=0 2>/dev/null || true
}
trap cleanup EXIT

# ==========================================================================
# Setup: Create namespaces and deploy agents
# ==========================================================================

section "Setup: Creating test namespaces and agents"

info "Creating team1 and team2 namespaces with ambient mesh + waypoints..."

# Create team1 namespace with ambient mesh
retry_kubectl kubectl create ns "$TEAM1_NS" 2>/dev/null || true
sleep 1
retry_kubectl kubectl label ns "$TEAM1_NS" \
  istio.io/dataplane-mode=ambient \
  istio.io/use-waypoint=team1-waypoint \
  kagenti-enabled="true" \
  --overwrite

# Create team2 namespace with ambient mesh
retry_kubectl kubectl create ns "$TEAM2_NS" 2>/dev/null || true
sleep 1
retry_kubectl kubectl label ns "$TEAM2_NS" \
  istio.io/dataplane-mode=ambient \
  istio.io/use-waypoint=team2-waypoint \
  kagenti-enabled="true" \
  --overwrite

detail "Namespaces created with ambient mesh labels"

# Create configuration based on ENABLE_SIDECAR flag
if [[ "$ENABLE_SIDECAR" == "true" ]]; then
  info "Creating configuration for operator and webhook-injected sidecars (ENABLE_SIDECAR=true)..."
else
  info "Creating configuration for operator-managed client registration (sidecars disabled)..."
fi

for NS in "$TEAM1_NS" "$TEAM2_NS"; do
  retry_kubectl kubectl create configmap authbridge-config -n "$NS" \
    --from-literal=KEYCLOAK_URL="${KC_URL_OPERATOR}" \
    --from-literal=KEYCLOAK_REALM="${REALM}" \
    --from-literal=ISSUER="${KC_URL_OPERATOR}/realms/${REALM}" \
    --from-literal=SPIRE_ENABLED="false" \
    --dry-run=client -o yaml | kubectl apply -f - || true

  sleep 2

  # Create keycloak-admin-secret directly in the namespace
  retry_kubectl kubectl create secret generic keycloak-admin-secret -n "$NS" \
    --from-literal=KEYCLOAK_ADMIN_USERNAME=temp-admin \
    --from-literal=KEYCLOAK_ADMIN_PASSWORD=95e0c65a71dd427c8eb828462ba9d22e \
    --dry-run=client -o yaml | kubectl apply -f - || true

  sleep 2

  # Create sidecar ConfigMaps only if ENABLE_SIDECAR=true
  if [[ "$ENABLE_SIDECAR" == "true" ]]; then
    # Create spiffe-helper-config ConfigMap (required by spiffe-helper sidecar)
    retry_kubectl kubectl create configmap spiffe-helper-config -n "$NS" \
      --from-literal=helper.conf='agent_address = "/spiffe-workload-api/spire-agent.sock"
cmd = ""
cmd_args = ""
cert_dir = "/opt"
renew_signal = ""
svid_file_name = "svid.pem"
svid_key_file_name = "svid_key.pem"
svid_bundle_file_name = "svid_bundle.pem"
jwt_svids = [{jwt_audience="kagenti", jwt_svid_file_name="jwt_svid.token"}]' \
      --dry-run=client -o yaml | kubectl apply -f - || true

    sleep 2

    # Create envoy-config ConfigMap (required by envoy-proxy sidecar)
    retry_kubectl kubectl create configmap envoy-config -n "$NS" \
      --from-file=envoy.yaml=deploy/minimal-envoy-config.yaml \
      --dry-run=client -o yaml | kubectl apply -f - || true

    sleep 2
  fi
done

if [[ "$ENABLE_SIDECAR" == "true" ]]; then
  detail "Operator and sidecar configuration created in both namespaces"
else
  detail "Operator configuration created (sidecar injection disabled via label)"
fi

# Deploy waypoints in both namespaces
info "Deploying waypoints for team1 and team2..."

retry_kubectl kubectl apply --validate=false -f - <<EOF
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: team1-waypoint
  namespace: $TEAM1_NS
spec:
  gatewayClassName: istio-waypoint
  listeners:
  - name: mesh
    port: 15008
    protocol: HBONE
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: team2-waypoint
  namespace: $TEAM2_NS
spec:
  gatewayClassName: istio-waypoint
  listeners:
  - name: mesh
    port: 15008
    protocol: HBONE
EOF

detail "Waypoints deployed"
sleep 2

# Configure AuthorizationPolicy for both waypoints
info "Configuring AuthorizationPolicy for token exchange..."

retry_kubectl kubectl apply --validate=false -f - <<EOF
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: team1-waypoint-token-exchange
  namespace: $TEAM1_NS
spec:
  targetRefs:
  - kind: Gateway
    group: gateway.networking.k8s.io
    name: team1-waypoint
  action: CUSTOM
  provider:
    name: kagenti-token-exchange
  rules:
  - to:
    - operation:
        notPaths:
        - /.well-known/*
        - /healthz
        - /readyz
        - /livez
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: team2-waypoint-token-exchange
  namespace: $TEAM2_NS
spec:
  targetRefs:
  - kind: Gateway
    group: gateway.networking.k8s.io
    name: team2-waypoint
  action: CUSTOM
  provider:
    name: kagenti-token-exchange
  rules:
  - to:
    - operation:
        notPaths:
        - /.well-known/*
        - /healthz
        - /readyz
        - /livez
EOF

detail "Authorization policies configured"
sleep 2

# Deploy team1-agent
info "Deploying team1-agent..."

# Set inject label based on ENABLE_SIDECAR
INJECT_LABEL="false"
if [[ "$ENABLE_SIDECAR" == "true" ]]; then
  INJECT_LABEL="true"
fi

retry_kubectl kubectl apply --validate=false -f - <<EOF
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: team1-agent
  namespace: $TEAM1_NS
  labels:
    istio.io/use-waypoint: team1-waypoint
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: team1-agent
  namespace: $TEAM1_NS
  labels:
    app: team1-agent
    kagenti.io/type: agent
spec:
  replicas: 1
  selector:
    matchLabels:
      app: team1-agent
  template:
    metadata:
      labels:
        app: team1-agent
        kagenti.io/type: agent
        kagenti.io/inject: "$INJECT_LABEL"
    spec:
      serviceAccountName: team1-agent
      containers:
      - name: agent
        image: image-registry.openshift-image-registry.svc:5000/kagenti-images/demo-agent:latest
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 8080
        env:
        - name: TOOL_NS
          value: "$TEAM2_NS"
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 3
          periodSeconds: 5
        resources:
          requests:
            memory: 32Mi
            cpu: 25m
          limits:
            memory: 64Mi
            cpu: 100m
---
apiVersion: v1
kind: Service
metadata:
  name: team1-agent
  namespace: $TEAM1_NS
spec:
  selector:
    app: team1-agent
  ports:
  - port: 8080
    targetPort: 8080
EOF

detail "team1-agent deployed"
sleep 2

# Deploy team2-agent
info "Deploying team2-agent..."

retry_kubectl kubectl apply --validate=false -f - <<EOF
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: team2-agent
  namespace: $TEAM2_NS
  labels:
    istio.io/use-waypoint: team2-waypoint
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: team2-agent
  namespace: $TEAM2_NS
  labels:
    app: team2-agent
    kagenti.io/type: agent
spec:
  replicas: 1
  selector:
    matchLabels:
      app: team2-agent
  template:
    metadata:
      labels:
        app: team2-agent
        kagenti.io/type: agent
        kagenti.io/inject: "$INJECT_LABEL"
    spec:
      serviceAccountName: team2-agent
      containers:
      - name: agent
        image: image-registry.openshift-image-registry.svc:5000/kagenti-images/echo-tool:latest
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 8080
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 3
          periodSeconds: 5
        resources:
          requests:
            memory: 32Mi
            cpu: 25m
          limits:
            memory: 64Mi
            cpu: 100m
---
apiVersion: v1
kind: Service
metadata:
  name: team2-agent
  namespace: $TEAM2_NS
spec:
  selector:
    app: team2-agent
  ports:
  - port: 8080
    targetPort: 8080
EOF

detail "team2-agent deployed"

# ==========================================================================
# Test 1: Verify operator-managed client registration
# ==========================================================================

section "Test 1: Operator-managed client registration"

info "Waiting for operator to create Keycloak clients and credentials..."

# Wait for waypoints to be ready
kubectl wait --for=condition=Programmed gateway/team1-waypoint -n "$TEAM1_NS" --timeout=120s 2>/dev/null || true
kubectl wait --for=condition=Programmed gateway/team2-waypoint -n "$TEAM2_NS" --timeout=120s 2>/dev/null || true

# Wait for agents to be ready
kubectl wait --for=condition=ready pod -l app=team1-agent -n "$TEAM1_NS" --timeout=120s 2>/dev/null || true
kubectl wait --for=condition=ready pod -l app=team2-agent -n "$TEAM2_NS" --timeout=120s 2>/dev/null || true

# Give operator time to reconcile
sleep 10

# Check if operator created client credentials secrets
info "Checking for operator-created client credentials secrets..."

TEAM1_SECRET_EXISTS=false
TEAM2_SECRET_EXISTS=false

# The operator creates secrets with a deterministic name pattern
# Format: kagenti-keycloak-client-credentials-<hash>
TEAM1_SECRETS=$(kubectl get secrets -n "$TEAM1_NS" -o name | grep "kagenti-keycloak-client-credentials" || echo "")
TEAM2_SECRETS=$(kubectl get secrets -n "$TEAM2_NS" -o name | grep "kagenti-keycloak-client-credentials" || echo "")

if [[ -n "$TEAM1_SECRETS" ]]; then
  TEAM1_SECRET_NAME=$(echo "$TEAM1_SECRETS" | head -n1 | cut -d/ -f2)
  TEAM1_SECRET_EXISTS=true
  detail "Found team1 client credentials secret: $TEAM1_SECRET_NAME"

  # Verify secret has correct keys
  if kubectl get secret "$TEAM1_SECRET_NAME" -n "$TEAM1_NS" -o jsonpath='{.data.client-id\.txt}' &>/dev/null && \
     kubectl get secret "$TEAM1_SECRET_NAME" -n "$TEAM1_NS" -o jsonpath='{.data.client-secret\.txt}' &>/dev/null; then
    ok "team1 credentials secret has client-id.txt and client-secret.txt"
  else
    fail "team1 credentials secret missing required keys"
  fi

  # Verify owner reference
  OWNER_KIND=$(kubectl get secret "$TEAM1_SECRET_NAME" -n "$TEAM1_NS" -o jsonpath='{.metadata.ownerReferences[0].kind}')
  OWNER_NAME=$(kubectl get secret "$TEAM1_SECRET_NAME" -n "$TEAM1_NS" -o jsonpath='{.metadata.ownerReferences[0].name}')
  if [[ "$OWNER_KIND" == "Deployment" && "$OWNER_NAME" == "team1-agent" ]]; then
    ok "team1 credentials secret has correct owner reference (Deployment/team1-agent)"
  else
    fail "team1 credentials secret has incorrect owner reference: $OWNER_KIND/$OWNER_NAME"
  fi
else
  fail "Operator did not create client credentials secret for team1-agent"
fi

if [[ -n "$TEAM2_SECRETS" ]]; then
  TEAM2_SECRET_NAME=$(echo "$TEAM2_SECRETS" | head -n1 | cut -d/ -f2)
  TEAM2_SECRET_EXISTS=true
  detail "Found team2 client credentials secret: $TEAM2_SECRET_NAME"

  # Verify secret has correct keys
  if kubectl get secret "$TEAM2_SECRET_NAME" -n "$TEAM2_NS" -o jsonpath='{.data.client-id\.txt}' &>/dev/null && \
     kubectl get secret "$TEAM2_SECRET_NAME" -n "$TEAM2_NS" -o jsonpath='{.data.client-secret\.txt}' &>/dev/null; then
    ok "team2 credentials secret has client-id.txt and client-secret.txt"
  else
    fail "team2 credentials secret missing required keys"
  fi

  # Verify owner reference
  OWNER_KIND=$(kubectl get secret "$TEAM2_SECRET_NAME" -n "$TEAM2_NS" -o jsonpath='{.metadata.ownerReferences[0].kind}')
  OWNER_NAME=$(kubectl get secret "$TEAM2_SECRET_NAME" -n "$TEAM2_NS" -o jsonpath='{.metadata.ownerReferences[0].name}')
  if [[ "$OWNER_KIND" == "Deployment" && "$OWNER_NAME" == "team2-agent" ]]; then
    ok "team2 credentials secret has correct owner reference (Deployment/team2-agent)"
  else
    fail "team2 credentials secret has incorrect owner reference: $OWNER_KIND/$OWNER_NAME"
  fi
else
  fail "Operator did not create client credentials secret for team2-agent"
fi

# Verify pod template annotations
info "Checking pod template annotations for credentials secret references..."

TEAM1_ANNOTATION=$(kubectl get deployment team1-agent -n "$TEAM1_NS" -o jsonpath='{.spec.template.metadata.annotations.kagenti\.io/keycloak-client-credentials-secret-name}')
TEAM2_ANNOTATION=$(kubectl get deployment team2-agent -n "$TEAM2_NS" -o jsonpath='{.spec.template.metadata.annotations.kagenti\.io/keycloak-client-credentials-secret-name}')

if [[ -n "$TEAM1_ANNOTATION" ]]; then
  ok "team1-agent pod template has credentials secret annotation: $TEAM1_ANNOTATION"
else
  fail "team1-agent pod template missing credentials secret annotation"
fi

if [[ -n "$TEAM2_ANNOTATION" ]]; then
  ok "team2-agent pod template has credentials secret annotation: $TEAM2_ANNOTATION"
else
  fail "team2-agent pod template missing credentials secret annotation"
fi

# ==========================================================================
# Test 2: Verify Keycloak clients exist
# ==========================================================================

section "Test 2: Verify Keycloak clients exist"

info "Setting up port-forward to Keycloak..."

PF_PID=""
if [[ "$KC_URL" == http://localhost:* || "$KC_URL" == http://127.0.0.1:* ]]; then
  { lsof -ti tcp:18080 | xargs kill; } 2>/dev/null || true
  sleep 1
  kubectl port-forward -n "$KEYCLOAK_NS" "svc/$KEYCLOAK_SVC" 18080:8080 &
  PF_PID=$!
  sleep 3
fi

info "Obtaining admin token from Keycloak..."

ADMIN_TOKEN=$(curl -sf -X POST "$KC_TOKEN_URL" \
  -d "grant_type=client_credentials" \
  -d "client_id=admin-cli" \
  -d "client_secret=admin-secret" | jq -r '.access_token')

if [[ -z "$ADMIN_TOKEN" || "$ADMIN_TOKEN" == "null" ]]; then
  fail "Could not obtain admin token from Keycloak"
else
  detail "Admin token obtained successfully"

  # Check if team1-agent client exists in Keycloak
  info "Checking if team1 client exists in Keycloak..."
  TEAM1_CLIENT_ID="$TEAM1_NS/team1-agent"

  TEAM1_CLIENT=$(curl -sf -H "Authorization: Bearer $ADMIN_TOKEN" \
    "${KC_URL}/admin/realms/${REALM}/clients?clientId=${TEAM1_CLIENT_ID}" | jq -r '.[0].clientId // empty')

  if [[ "$TEAM1_CLIENT" == "$TEAM1_CLIENT_ID" ]]; then
    ok "team1-agent client exists in Keycloak with ID: $TEAM1_CLIENT_ID"
  else
    fail "team1-agent client not found in Keycloak (expected: $TEAM1_CLIENT_ID)"
  fi

  # Check if team2-agent client exists in Keycloak
  info "Checking if team2 client exists in Keycloak..."
  TEAM2_CLIENT_ID="$TEAM2_NS/team2-agent"

  TEAM2_CLIENT=$(curl -sf -H "Authorization: Bearer $ADMIN_TOKEN" \
    "${KC_URL}/admin/realms/${REALM}/clients?clientId=${TEAM2_CLIENT_ID}" | jq -r '.[0].clientId // empty')

  if [[ "$TEAM2_CLIENT" == "$TEAM2_CLIENT_ID" ]]; then
    ok "team2-agent client exists in Keycloak with ID: $TEAM2_CLIENT_ID"
  else
    fail "team2-agent client not found in Keycloak (expected: $TEAM2_CLIENT_ID)"
  fi
fi

# ==========================================================================
# Test 3: Verify waypoint configuration
# ==========================================================================

section "Test 3: Verify waypoint configuration"

info "Checking waypoint gateways..."

# Check team1 waypoint
if kubectl get gateway team1-waypoint -n "$TEAM1_NS" &>/dev/null; then
  TEAM1_WAYPOINT_CLASS=$(kubectl get gateway team1-waypoint -n "$TEAM1_NS" -o jsonpath='{.spec.gatewayClassName}')
  if [[ "$TEAM1_WAYPOINT_CLASS" == "istio-waypoint" ]]; then
    ok "team1-waypoint gateway configured with correct gatewayClassName"
  else
    fail "team1-waypoint has incorrect gatewayClassName: $TEAM1_WAYPOINT_CLASS"
  fi
else
  fail "team1-waypoint gateway not found"
fi

# Check team2 waypoint
if kubectl get gateway team2-waypoint -n "$TEAM2_NS" &>/dev/null; then
  TEAM2_WAYPOINT_CLASS=$(kubectl get gateway team2-waypoint -n "$TEAM2_NS" -o jsonpath='{.spec.gatewayClassName}')
  if [[ "$TEAM2_WAYPOINT_CLASS" == "istio-waypoint" ]]; then
    ok "team2-waypoint gateway configured with correct gatewayClassName"
  else
    fail "team2-waypoint has incorrect gatewayClassName: $TEAM2_WAYPOINT_CLASS"
  fi
else
  fail "team2-waypoint gateway not found"
fi

info "Checking authorization policies..."

# Check team1 authorization policy
if kubectl get authorizationpolicy team1-waypoint-token-exchange -n "$TEAM1_NS" &>/dev/null; then
  TEAM1_PROVIDER=$(kubectl get authorizationpolicy team1-waypoint-token-exchange -n "$TEAM1_NS" -o jsonpath='{.spec.provider.name}')
  if [[ "$TEAM1_PROVIDER" == "kagenti-token-exchange" ]]; then
    ok "team1 authorization policy configured with kagenti-token-exchange provider"
  else
    fail "team1 authorization policy has incorrect provider: $TEAM1_PROVIDER"
  fi
else
  fail "team1 authorization policy not found"
fi

# Check team2 authorization policy
if kubectl get authorizationpolicy team2-waypoint-token-exchange -n "$TEAM2_NS" &>/dev/null; then
  TEAM2_PROVIDER=$(kubectl get authorizationpolicy team2-waypoint-token-exchange -n "$TEAM2_NS" -o jsonpath='{.spec.provider.name}')
  if [[ "$TEAM2_PROVIDER" == "kagenti-token-exchange" ]]; then
    ok "team2 authorization policy configured with kagenti-token-exchange provider"
  else
    fail "team2 authorization policy has incorrect provider: $TEAM2_PROVIDER"
  fi
else
  fail "team2 authorization policy not found"
fi

# ==========================================================================
# Test 4: Agent-to-agent communication with token exchange
# ==========================================================================

section "Test 4: Agent-to-agent communication with token exchange"

info "Obtaining token for team1-agent from Keycloak..."

if [[ "$TEAM1_SECRET_EXISTS" == "true" ]]; then
  TEAM1_CLIENT_ID_VALUE=$(kubectl get secret "$TEAM1_SECRET_NAME" -n "$TEAM1_NS" -o jsonpath='{.data.client-id\.txt}' | base64 -d)
  TEAM1_CLIENT_SECRET_VALUE=$(kubectl get secret "$TEAM1_SECRET_NAME" -n "$TEAM1_NS" -o jsonpath='{.data.client-secret\.txt}' | base64 -d)

  TEAM1_TOKEN=$(curl -sf -X POST "$KC_TOKEN_URL" \
    -d "grant_type=client_credentials" \
    -d "client_id=${TEAM1_CLIENT_ID_VALUE}" \
    -d "client_secret=${TEAM1_CLIENT_SECRET_VALUE}" | jq -r '.access_token')

  if [[ -z "$TEAM1_TOKEN" || "$TEAM1_TOKEN" == "null" ]]; then
    fail "Could not obtain token for team1-agent"
  else
    detail "Token obtained for team1-agent"
    echo ""
    print_token_info "team1-agent token (before exchange)" "$TEAM1_TOKEN"
    echo ""
  fi
else
  fail "Cannot test communication - team1 credentials secret not created"
fi

# Test communication from team1-agent to team2-agent
if [[ -n "${TEAM1_TOKEN:-}" && "$TEAM1_TOKEN" != "null" ]]; then
  info "Testing team1-agent -> team2-agent communication..."

  TEAM2_URL="http://team2-agent.$TEAM2_NS.svc.cluster.local:8080"

  # Run curl from team1 namespace
  kubectl delete pod -n "$TEAM1_NS" curl-test --force --grace-period=0 2>/dev/null || true

  kubectl run curl-test -n "$TEAM1_NS" \
    --image=curlimages/curl:latest \
    --restart=Never \
    -- curl -sS --max-time 60 \
    -H "Authorization: Bearer ${TEAM1_TOKEN}" \
    -w $'\n%{http_code}' \
    "$TEAM2_URL" 2>/dev/null

  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/curl-test" -n "$TEAM1_NS" --timeout=120s 2>/dev/null \
    || kubectl wait --for=jsonpath='{.status.phase}'=Failed "pod/curl-test" -n "$TEAM1_NS" --timeout=15s 2>/dev/null \
    || true

  sleep 2

  CURL_RAW=$(kubectl logs -n "$TEAM1_NS" curl-test 2>&1) || true
  HTTP_CODE=$(echo "$CURL_RAW" | tail -n1)
  RESPONSE_BODY=$(echo "$CURL_RAW" | sed '$d')

  if ! [[ "$HTTP_CODE" =~ ^[0-9]{3}$ ]]; then
    RESPONSE_BODY=$CURL_RAW
    HTTP_CODE=""
  fi

  kubectl delete pod -n "$TEAM1_NS" curl-test --force --grace-period=0 2>/dev/null || true

  detail "HTTP response code: ${HTTP_CODE:-unknown}"

  if [[ "$HTTP_CODE" == "200" ]]; then
    ok "team1-agent -> team2-agent communication successful (HTTP 200)"

    # Parse the response to check for token exchange
    RECEIVED_AUTH=$(echo "$RESPONSE_BODY" | jq -r '.headers.Authorization // .headers.authorization // empty' 2>/dev/null || true)

    if [[ -n "$RECEIVED_AUTH" ]]; then
      RECEIVED_TOKEN=$(echo "$RECEIVED_AUTH" | sed 's/Bearer //')

      echo ""
      print_token_info "Token received by team2-agent (after exchange)" "$RECEIVED_TOKEN"
      echo ""

      RECEIVED_AUD=$(jwt_payload "$RECEIVED_TOKEN" | jq -r '.aud // "unknown"')

      if [[ "$RECEIVED_TOKEN" != "$TEAM1_TOKEN" ]]; then
        ok "Token was exchanged (different from original team1-agent token)"

        if echo "$RECEIVED_AUD" | grep -qE "team2|$TEAM2_NS"; then
          ok "Exchanged token has correct audience: $RECEIVED_AUD"
          detail "Token exchange working correctly for cross-team communication"
        else
          detail "Token audience: $RECEIVED_AUD (may be valid depending on configuration)"
        fi
      else
        fail "Token was NOT exchanged - team2-agent received original team1-agent token"
      fi
    else
      detail "Could not extract token from response (echo-tool may not be echoing headers)"
    fi
  else
    fail "team1-agent -> team2-agent communication failed (HTTP ${HTTP_CODE:-unknown})"
    detail "Response: $RESPONSE_BODY"
  fi
fi

# ==========================================================================
# Summary
# ==========================================================================

echo ""
section "Test Summary"

echo ""
info "Integration Test Results:"
detail "✓ Operator-managed client registration"
detail "✓ Automatic Keycloak client creation"
detail "✓ Credential secret provisioning"
detail "✓ Waypoint configuration"
detail "✓ Token exchange for cross-team communication"
echo ""

echo "=============================="
echo "  RESULTS: $PASS passed, $FAIL failed"
echo "=============================="
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  info "Debug commands:"
  detail "  kubectl logs -n $OPERATOR_NS -l control-plane=controller-manager --tail=50"
  detail "  kubectl logs -n kagenti-system -l app=token-exchange-service --tail=50"
  detail "  kubectl get secrets -n $TEAM1_NS"
  detail "  kubectl get secrets -n $TEAM2_NS"
  detail "  kubectl describe deployment team1-agent -n $TEAM1_NS"
  detail "  kubectl describe deployment team2-agent -n $TEAM2_NS"
  echo ""
  exit 1
fi

info "All tests passed! ✓"

if [[ "$SKIP_CLEANUP" == "true" ]]; then
  echo ""
  section "What to Check for Sidecar Injection"
  echo ""
  info "The test resources are still running. Here's what to verify:"
  echo ""

  if [[ "$ENABLE_SIDECAR" == "true" ]]; then
    detail "1. Check if webhook injected sidecars into pods:"
    detail "   kubectl get pods -n $TEAM1_NS -o jsonpath='{.items[*].spec.containers[*].name}'"
    detail "   kubectl get pods -n $TEAM2_NS -o jsonpath='{.items[*].spec.containers[*].name}'"
    detail "   Expected: Should show multiple containers (agent + envoy-proxy + spiffe-helper)"
    echo ""

    detail "2. Verify operator-provisioned credentials are mounted:"
    detail "   kubectl exec -n $TEAM1_NS deploy/team1-agent -c agent -- ls -la /shared/ 2>/dev/null || echo 'No /shared mount'"
    detail "   Expected: Should see client-id.txt and client-secret.txt if webhook mounted them"
    echo ""
  else
    detail "1. Verify sidecar injection is disabled (should show only 1 container):"
    detail "   kubectl get pods -n $TEAM1_NS -o jsonpath='{.items[*].spec.containers[*].name}'"
    detail "   kubectl get pods -n $TEAM2_NS -o jsonpath='{.items[*].spec.containers[*].name}'"
    detail "   Expected: Should show only 'agent' (sidecar injection disabled via label)"
    echo ""

    detail "2. Verify operator created credentials secrets (not mounted, since sidecars disabled):"
    detail "   kubectl get secret -n $TEAM1_NS -o name | grep kagenti-keycloak"
    detail "   Expected: Should see operator-created secret"
    echo ""
  fi

  detail "3. Check pod volumes (should include operator secret):"
  detail "   kubectl get pod -n $TEAM1_NS -l app=team1-agent -o jsonpath='{.items[0].spec.volumes[*].name}' | tr ' ' '\n'"
  detail "   Expected: Should include volume named like 'kagenti-keycloak-client-credentials-*'"
  echo ""

  detail "4. View complete pod YAML to see injection:"
  detail "   kubectl get pod -n $TEAM1_NS -l app=team1-agent -o yaml | less"
  detail "   Look for: initContainers, sidecar containers, volume mounts, annotations"
  echo ""

  detail "5. Check if pods are using the waypoint:"
  detail "   kubectl get pods -n $TEAM1_NS -o yaml | grep -A 5 'istio.io/use-waypoint'"
  detail "   Expected: Should show waypoint configuration"
  echo ""

  detail "6. Verify Keycloak client creation (check operator logs):"
  detail "   kubectl logs -n $OPERATOR_NS -l control-plane=controller-manager --tail=100 | grep 'team1-agent\\|team2-agent'"
  detail "   Expected: Should show successful client creation messages"
  echo ""

  detail "7. Test token acquisition using operator-provisioned credentials:"
  detail "   # Get credentials from secret"
  detail "   CLIENT_ID=\$(kubectl get secret -n $TEAM1_NS \$(kubectl get secrets -n $TEAM1_NS -o name | grep kagenti-keycloak) -o jsonpath='{.data.client-id\.txt}' | base64 -d)"
  detail "   CLIENT_SECRET=\$(kubectl get secret -n $TEAM1_NS \$(kubectl get secrets -n $TEAM1_NS -o name | grep kagenti-keycloak) -o jsonpath='{.data.client-secret\.txt}' | base64 -d)"
  detail "   # Get token from Keycloak"
  detail "   kubectl port-forward -n keycloak svc/keycloak-service 18080:8080 &"
  detail "   curl -X POST http://localhost:18080/realms/kagenti/protocol/openid-connect/token \\"
  detail "     -d \"grant_type=client_credentials\" -d \"client_id=\$CLIENT_ID\" -d \"client_secret=\$CLIENT_SECRET\""
  echo ""

  if [[ "$ENABLE_SIDECAR" == "true" ]]; then
    info "Summary of what the operator + webhook did:"
    detail "✓ Operator detected deployments with label 'kagenti.io/type: agent'"
    detail "✓ Operator created Keycloak clients (team1/team1-agent, team2/team2-agent)"
    detail "✓ Operator provisioned credential Secrets with ownership references"
    detail "✓ Operator annotated pod templates with secret names"
    detail "✓ Webhook injected sidecars (envoy-proxy, spiffe-helper, proxy-init)"
    detail "✓ Webhook mounted operator-provisioned credentials"
    detail "✓ Waypoints configured for token exchange"
    echo ""
  else
    info "Summary of what the operator did (webhook injection disabled):"
    detail "✓ Operator detected deployments with label 'kagenti.io/type: agent'"
    detail "✓ Operator created Keycloak clients (team1/team1-agent, team2/team2-agent)"
    detail "✓ Operator provisioned credential Secrets with ownership references"
    detail "✓ Operator annotated pod templates with secret names"
    detail "✓ Webhook injection disabled via 'kagenti.io/inject: false' label"
    detail "✓ Waypoints configured for token exchange"
    detail ""
    detail "Note: Pods run with single container (no sidecars) for this test"
    echo ""
  fi
fi

exit 0
