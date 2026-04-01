# Operator Client Registration Integration with Token Exchange Service

This document explains how the **kagenti-operator** client registration feature (from [kagenti/kagenti-operator#247](https://github.com/kagenti/kagenti-operator/pull/247)) integrates with the **authbridge-waypoint** token-exchange-service to provide a complete authentication and authorization solution.

## Table of Contents

- [Overview](#overview)
- [Two-Phase Security Model](#two-phase-security-model)
- [Phase 1: Client Lifecycle Management (Operator)](#phase-1-client-lifecycle-management-operator)
- [Phase 2: Runtime Token Exchange (Service)](#phase-2-runtime-token-exchange-service)
- [Key Integration Points](#key-integration-points)
- [Complete E2E Flow Example](#complete-e2e-flow-example)
- [Why Both Components Are Needed](#why-both-components-are-needed)
- [Configuration Requirements](#configuration-requirements)
- [Troubleshooting](#troubleshooting)

## Overview

The **kagenti-operator** and **token-exchange-service** work together in a **two-phase** security model:

1. **Phase 1 (Build-time)**: Operator manages Keycloak client registration and credentials provisioning
2. **Phase 2 (Runtime)**: token-exchange-service performs JWT validation and RFC 8693 token exchange

This separation of concerns enables:
- Platform teams to manage client registration centrally
- Security teams to enforce least-privilege tokens via audience scoping
- Application teams to deploy agents/tools without manual Keycloak setup
- Zero per-pod overhead (no client-registration sidecar needed)

## Two-Phase Security Model

```
┌───────────────────────────────────────────────────────────────┐
│                    PHASE 1: CLIENT LIFECYCLE                  │
│                    (kagenti-operator)                         │
└───────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│ kagenti-operator ClientRegistrationReconciler              │
│                                                             │
│  Watches: Deployments/StatefulSets                         │
│  Labels: kagenti.io/type=agent|tool                        │
│                                                             │
│  For each workload:                                         │
│  1. Reads authbridge-config (Keycloak URL, realm)          │
│  2. Reads keycloak-admin-secret (admin credentials)        │
│  3. Registers client in Keycloak via admin API             │
│  4. Creates Secret with client-id/client-secret            │
│  5. Annotates pod template for webhook mounting            │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
                        Keycloak
          (Clients registered with credentials)
                              │
                              ▼
┌───────────────────────────────────────────────────────────────┐
│                   PHASE 2: RUNTIME TOKEN EXCHANGE             │
│                   (token-exchange-service)                    │
└───────────────────────────────────────────────────────────────┘
                              │
                              ▼
         User → Agent → Tool (cross-service call)
                              │
                              ▼
                    Istio Waypoint (ext_authz)
                              │
                              ▼
                  token-exchange-service
                              │
                    ┌─────────┴─────────┐
                    │                   │
            JWT Validation      Token Exchange
            (JWKS cache)        (RFC 8693)
                    │                   │
                    └─────────┬─────────┘
                              ▼
                    Forward with correct token
```

## Phase 1: Client Lifecycle Management (Operator)

The operator manages **Keycloak client registration and credentials** for agent/tool workloads.

### Client ID Naming Convention

From operator code (`clientregistration_controller.go`):

- **Without SPIRE**: `namespace/workloadName`
  - Example: `tool-ns/echo-tool`, `agent-ns/demo-agent`

- **With SPIRE**: `spiffe://<trust-domain>/ns/<namespace>/sa/<serviceAccount>`
  - Example: `spiffe://cluster.local/ns/agent-ns/sa/demo-agent-sa`

### Operator Registration Flow

```go
// Simplified from internal/controller/clientregistration_controller.go

1. Watch Deployments/StatefulSets with:
   - kagenti.io/type=agent|tool
   - kagenti.io/client-registration-inject != "true" (default mode)

2. For each workload:
   a. Read authbridge-config ConfigMap (namespace-scoped)
      - KEYCLOAK_URL
      - KEYCLOAK_REALM
      - SPIRE_ENABLED

   b. Read keycloak-admin-secret Secret (namespace-scoped)
      - KEYCLOAK_ADMIN_USERNAME
      - KEYCLOAK_ADMIN_PASSWORD

   c. Compute client ID:
      if SPIRE_ENABLED:
          clientID = spiffe://<trust-domain>/ns/<ns>/sa/<sa>
      else:
          clientID = namespace/workloadName

   d. Call Keycloak admin API (internal/keycloak/admin.go):
      POST /admin/realms/{realm}/clients
      {
        "clientId": "agent-ns/demo-agent",
        "name": "demo-agent",
        "standardFlowEnabled": true,
        "directAccessGrantsEnabled": true,
        "serviceAccountsEnabled": true,
        "fullScopeAllowed": false,
        "publicClient": false,
        "clientAuthenticatorType": "client-secret",
        "attributes": {
          "standard.token.exchange.enabled": "true"  // ← CRITICAL
        }
      }

   e. Create Secret:
      apiVersion: v1
      kind: Secret
      metadata:
        name: kagenti-keycloak-client-credentials-<hash>
        namespace: agent-ns
        ownerReferences: [<Deployment>]
      data:
        client-id.txt: <base64(clientID)>
        client-secret.txt: <base64(secret from Keycloak)>

   f. Patch pod template annotation:
      kagenti.io/keycloak-client-credentials-secret-name:
        kagenti-keycloak-client-credentials-<hash>
```

### Critical Attribute: `standard.token.exchange.enabled`

From `internal/keycloak/admin.go`:

```go
attrs := map[string]string{
    "standard.token.exchange.enabled": fmt.Sprintf("%t", p.TokenExchangeEnable),
    // ^^^^ This enables the client to be used as an AUDIENCE target
    //      in RFC 8693 token exchange requests
}
```

This attribute tells Keycloak:
- ✅ This client can be specified as the `audience` parameter in token exchange requests
- ✅ token-exchange-service is allowed to exchange tokens FOR this client
- ❌ Without this, token exchange will fail with "audience not allowed"

## Phase 2: Runtime Token Exchange (Service)

The token-exchange-service performs **runtime JWT validation and RFC 8693 token exchange**.

### Service Architecture

From `cmd/token-exchange-service/main.go`:

```go
// Config holds service configuration
type Config struct {
    KeycloakURL  string // e.g. http://keycloak-service.keycloak.svc:8080
    IssuerURL    string // Issuer in JWT claims
    Realm        string // e.g. kagenti
    ClientID     string // token-exchange-service's OWN client ID
    ClientSecret string // token-exchange-service's OWN client secret
    // ...
}

// Dual interface:
// 1. gRPC ext_authz (Istio waypoints)
// 2. HTTP forward proxy (HTTP_PROXY env var)
```

### Token Exchange Flow

From `exchangeToken()` function (lines 543-590):

```go
func exchangeToken(ctx context.Context, subjectToken, audience string) (string, int, error) {
    tokenURL := fmt.Sprintf("%s/realms/%s/protocol/openid-connect/token",
        cfg.KeycloakURL, cfg.Realm)

    data := url.Values{
        "grant_type":         {"urn:ietf:params:oauth:grant-type:token-exchange"},
        "subject_token":      {subjectToken},           // ← Token issued to "agent-ns/demo-agent"
        "subject_token_type": {"urn:ietf:params:oauth:token-type:access_token"},
        "audience":           {audience},                // ← Target: "echo-tool"
        "client_id":          {cfg.ClientID},           // ← "token-exchange-service"
        "client_secret":      {cfg.ClientSecret},       // ← Service's credentials
    }

    // POST to Keycloak
    // Returns new JWT with aud=[audience], sub=<original-user>
}
```

**Critical insight**:
- token-exchange-service authenticates to Keycloak using **its own credentials**
- But the `subject_token` was issued to the **operator-registered client** (e.g., `agent-ns/demo-agent`)
- The `audience` parameter references **another operator-registered client** (e.g., `echo-tool`)
- Keycloak validates that both clients have `standard.token.exchange.enabled=true`

### Authorization Decision Logic

From `evaluateAuth()` function (lines 247-304):

```go
func evaluateAuth(ctx context.Context, authHeader, host, reqPath string) *authDecision {
    // 1. Extract and validate JWT
    claims, err := validateJWT(tokenStr)
    if err != nil {
        return deny("invalid token")
    }

    // 2. Derive destination audience from hostname
    // e.g. "echo-tool.tool-ns.svc.cluster.local" → "echo-tool"
    audience := serviceNameFromHost(stripPort(host))

    // 3. Check if token already authorized for destination
    if claims.hasAudience(audience) {
        log.Printf("token already authorized for %s, passing through", audience)
        return allow()
    }

    // 4. Check cache (avoid repeated exchanges)
    cacheKey := hashCacheKey(tokenStr, audience)
    if cached, ok := cache.get(cacheKey); ok {
        return allowWithToken(cached)
    }

    // 5. Perform RFC 8693 token exchange
    exchangedToken, expiresIn, err := exchangeToken(ctx, tokenStr, audience)
    if err != nil {
        return deny("token exchange failed")
    }

    // 6. Cache and return
    cache.set(cacheKey, exchangedToken, ttl)
    return allowWithToken(exchangedToken)
}
```

## Key Integration Points

### 1. Separate Keycloak Clients

**Operator creates** (per workload):
```yaml
Client: agent-ns/demo-agent
  clientId: "agent-ns/demo-agent"
  client_secret: <generated by Keycloak>
  attributes:
    standard.token.exchange.enabled: "true"
  Used by: demo-agent pod for initial authentication

Client: tool-ns/echo-tool
  clientId: "tool-ns/echo-tool"
  client_secret: <generated by Keycloak>
  attributes:
    standard.token.exchange.enabled: "true"
  Used as: audience target in token exchanges
```

**Platform team provisions** (token-exchange-service):
```yaml
Client: token-exchange-service
  clientId: "token-exchange-service"
  client_secret: <configured in deployment>
  attributes:
    standard.token.exchange.enabled: "true"
  Used for: Authenticating token exchange requests
```

### 2. Token Exchange Permissions

For token exchange to work, Keycloak must have **token exchange permissions** configured:

**Option 1: Keycloak Admin UI**
```
Clients → token-exchange-service → Permissions → Token Exchange

Enable token exchange:
  ✓ Allow exchanges from any client to any client (with standard.token.exchange.enabled)
  ✓ Or configure fine-grained policies (e.g., only agent → tool)
```

**Option 2: Keycloak Admin API** (when operator registers clients)
```
The operator sets standard.token.exchange.enabled=true on each client,
which enables that client to participate in token exchanges.
```

### 3. Credential Flow

```
User authenticates:
  → Keycloak issues JWT:
      {
        "iss": "https://keycloak.example.com/realms/kagenti",
        "sub": "<user-id>",
        "azp": "agent-ns/demo-agent",          ← Issued TO this client
        "aud": [
          "agent-ns/demo-agent",                ← Can call agent
          "token-exchange-service"              ← Can request exchanges
        ],
        "exp": 1234567890
      }

Agent receives credentials (mounted by kagenti-webhook):
  /shared/client-id.txt      → "agent-ns/demo-agent"
  /shared/client-secret.txt  → "<secret from operator>"

Agent uses credentials:
  → Initial auth to Keycloak → receives JWT (above)
  → Calls tool with this JWT

Tool waypoint:
  → ext_authz (token-exchange-service)
  → Service checks: aud includes "echo-tool"? NO
  → Exchanges token:
      POST /realms/kagenti/protocol/openid-connect/token
      {
        "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
        "subject_token": "<agent's JWT>",
        "audience": "echo-tool",
        "client_id": "token-exchange-service",    ← Service's credentials
        "client_secret": "<service secret>"
      }
  → Returns new JWT:
      {
        "iss": "https://keycloak.example.com/realms/kagenti",
        "sub": "<same-user-id>",                  ← Preserved subject
        "azp": "token-exchange-service",          ← Issued BY exchange service
        "aud": ["echo-tool"],                     ← NEW audience
        "exp": 1234567890
      }
```

## Complete E2E Flow Example

### Setup Phase (Operator)

```bash
# 1. Deploy agent workload
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-agent
  namespace: agent-ns
spec:
  template:
    metadata:
      labels:
        kagenti.io/type: agent  # ← Triggers operator reconciliation
    spec:
      containers:
      - name: agent
        image: demo-agent:latest
EOF

# 2. Operator reconciles:
#    - Reads authbridge-config and keycloak-admin-secret
#    - Registers "agent-ns/demo-agent" in Keycloak
#    - Creates Secret: kagenti-keycloak-client-credentials-<hash>
#    - Patches Deployment with annotation

# 3. kagenti-webhook mutates pod:
#    - Injects envoy/authbridge sidecars
#    - Mounts client credentials Secret to /shared/
```

### Runtime Phase (Token Exchange Service)

```
1. User authenticates to Keycloak
   POST /realms/kagenti/protocol/openid-connect/token
   {
     "grant_type": "password",
     "client_id": "agent-ns/demo-agent",
     "client_secret": "<from Secret>",
     "username": "alice",
     "password": "password123"
   }

   ← Returns JWT:
     {
       "sub": "user-alice",
       "azp": "agent-ns/demo-agent",
       "aud": ["agent-ns/demo-agent", "token-exchange-service"],
       "exp": 1234567890
     }

2. User calls demo-agent with this JWT
   curl -H "Authorization: Bearer <JWT>" http://demo-agent.agent-ns/query

   → Agent waypoint (ext_authz):
     - token-exchange-service checks: aud includes "demo-agent"? YES
     - Decision: PASS THROUGH ✅

   → Agent receives request with original JWT

3. Agent calls echo-tool with the SAME JWT
   curl -H "Authorization: Bearer <JWT>" http://echo-tool.tool-ns/echo

   → Tool waypoint (ext_authz):
     - token-exchange-service checks: aud includes "echo-tool"? NO
     - Check cache: MISS (first call)
     - Call Keycloak token exchange:
         POST /realms/kagenti/protocol/openid-connect/token
         {
           "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
           "subject_token": "<agent's JWT>",
           "audience": "echo-tool",
           "client_id": "token-exchange-service",
           "client_secret": "<service secret>"
         }
     - Keycloak validates:
         ✓ token-exchange-service is authenticated
         ✓ subject_token is valid and not expired
         ✓ "echo-tool" has standard.token.exchange.enabled=true (set by operator)
         ✓ Token exchange is permitted
     - Returns new JWT:
         {
           "sub": "user-alice",           ← SAME subject (user preserved)
           "azp": "token-exchange-service",
           "aud": ["echo-tool"],           ← NEW audience
           "exp": 1234567890
         }
     - Cache exchanged token (key = hash(original_token + "echo-tool"))
     - Decision: ALLOW_WITH_TOKEN ✅

   → Tool receives request with EXCHANGED JWT (aud=["echo-tool"])

4. Same user calls echo-tool again (within cache TTL)
   → Tool waypoint (ext_authz):
     - Check cache: HIT ✅
     - Return cached exchanged token
     - No Keycloak call (latency <1ms)
```

## Why Both Components Are Needed

| Component | Responsibility | Without It |
|-----------|---------------|------------|
| **kagenti-operator** | **Client Lifecycle Management**<br>- Register clients in Keycloak<br>- Provision credentials as Secrets<br>- Enable token exchange on clients<br>- Update clients when config drifts | **Manual registration per workload**<br>- Platform teams manually create Keycloak clients<br>- No standardized secret naming<br>- Credentials scattered/ad-hoc<br>- No drift reconciliation |
| **token-exchange-service** | **Runtime Authorization**<br>- JWT signature validation (JWKS)<br>- Audience checking<br>- RFC 8693 token exchange<br>- Token caching (performance) | **Broad audience tokens (security risk)**<br>- Every workload needs to know all possible destinations upfront<br>- No centralized validation<br>- Token reuse across services<br>- No caching (poor performance) |

### Separation of Concerns

```
┌──────────────────────────────────────────────────────────────┐
│                   Platform Team Concerns                     │
│                   (kagenti-operator)                         │
├──────────────────────────────────────────────────────────────┤
│ - Which workloads exist?                                     │
│ - What are their Keycloak client IDs?                        │
│ - How are credentials provisioned?                           │
│ - When do clients need updates (drift)?                      │
│ - How are secrets named and mounted?                         │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│                   Security Team Concerns                     │
│                   (token-exchange-service)                   │
├──────────────────────────────────────────────────────────────┤
│ - Is this JWT valid and not expired?                         │
│ - Is the token authorized for this destination?              │
│ - Should we pass through or exchange?                        │
│ - What is the least-privilege token for this call?           │
│ - How do we cache to minimize Keycloak load?                 │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│                   Application Team Concerns                  │
│                   (agent/tool developers)                    │
├──────────────────────────────────────────────────────────────┤
│ - Deploy with label: kagenti.io/type=agent                   │
│ - Credentials are auto-mounted to /shared/                   │
│ - Make HTTP calls with Authorization: Bearer <token>         │
│ - Everything else is handled by platform + security          │
└──────────────────────────────────────────────────────────────┘
```

## Configuration Requirements

### For kagenti-operator

```yaml
# Namespace-scoped ConfigMap (per agent namespace)
apiVersion: v1
kind: ConfigMap
metadata:
  name: authbridge-config
  namespace: agent-ns
data:
  KEYCLOAK_URL: "http://keycloak-service.keycloak.svc.cluster.local:8080"
  KEYCLOAK_REALM: "kagenti"
  SPIRE_ENABLED: "false"  # or "true" if using SPIRE

---
# Namespace-scoped Secret (per agent namespace)
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-admin-secret
  namespace: agent-ns
stringData:
  KEYCLOAK_ADMIN_USERNAME: "admin"
  KEYCLOAK_ADMIN_PASSWORD: "<admin-password>"
```

### For token-exchange-service

```yaml
# Deployment in kagenti-system namespace
apiVersion: apps/v1
kind: Deployment
metadata:
  name: token-exchange-service
  namespace: kagenti-system
spec:
  template:
    spec:
      containers:
      - name: token-exchange
        image: token-exchange-service:latest
        env:
        - name: KEYCLOAK_URL
          value: "http://keycloak-service.keycloak.svc.cluster.local:8080"
        - name: ISSUER_URL
          value: "https://keycloak.example.com/realms/kagenti"  # External URL
        - name: REALM
          value: "kagenti"
        - name: CLIENT_ID
          value: "token-exchange-service"
        - name: CLIENT_SECRET
          valueFrom:
            secretKeyRef:
              name: token-exchange-service-secret
              key: client-secret
        - name: LISTEN_ADDR
          value: ":9090"  # gRPC ext_authz
        - name: PROXY_LISTEN_ADDR
          value: ":8080"  # HTTP forward proxy (optional)
```

### For Keycloak

**Manual setup** (or Keycloak operator):

1. Create realm: `kagenti`
2. Create client: `token-exchange-service`
   - Client authentication: ON
   - Service accounts enabled: ON
   - Standard flow: ON
   - Direct access grants: ON
3. Configure token exchange permissions:
   - Navigate to: Clients → token-exchange-service → Permissions → Token Exchange
   - Enable token exchange for clients with `standard.token.exchange.enabled=true`

**The operator handles**:
- Creating agent/tool clients automatically
- Setting `standard.token.exchange.enabled=true`
- Managing client secrets

## Troubleshooting

### Issue: Token exchange fails with "audience not allowed"

**Symptoms**:
```
token exchange failed: token exchange returned 403: {"error":"audience not allowed"}
```

**Root cause**: Target client does not have `standard.token.exchange.enabled=true`

**Solution**:
```bash
# Check if operator registered the client correctly
kubectl logs -n kagenti-operator-system deployment/kagenti-operator | grep "echo-tool"

# Verify in Keycloak:
# Clients → echo-tool → Attributes → standard.token.exchange.enabled = true

# Force operator reconciliation:
kubectl annotate deployment -n tool-ns echo-tool reconcile="$(date +%s)"
```

### Issue: JWT validation fails with "invalid issuer"

**Symptoms**:
```
invalid issuer: got http://localhost:8080/realms/kagenti,
want https://keycloak.example.com/realms/kagenti
```

**Root cause**: `ISSUER_URL` env var mismatch between token issuance and validation

**Solution**:
```yaml
# token-exchange-service deployment:
env:
- name: ISSUER_URL
  value: "https://keycloak.example.com/realms/kagenti"  # Must match JWT iss claim
```

### Issue: Operator not registering clients

**Symptoms**:
```
kubectl get secret -n agent-ns | grep kagenti-keycloak-client-credentials
# (no results)
```

**Check**:
```bash
# 1. Verify operator is running
kubectl get pods -n kagenti-operator-system

# 2. Check operator logs
kubectl logs -n kagenti-operator-system deployment/kagenti-operator

# 3. Verify workload has correct labels
kubectl get deployment -n agent-ns demo-agent -o yaml | grep "kagenti.io/type"

# 4. Check if using legacy sidecar mode
kubectl get deployment -n agent-ns demo-agent -o yaml | grep "client-registration-inject"
# Should be absent or "false" for operator mode

# 5. Verify authbridge-config and keycloak-admin-secret exist
kubectl get configmap -n agent-ns authbridge-config
kubectl get secret -n agent-ns keycloak-admin-secret
```

### Issue: High latency on first call to a service

**Expected behavior**: First call to a new service triggers token exchange (~50-100ms latency)

**Verify caching is working**:
```bash
# Check token-exchange-service logs
kubectl logs -n kagenti-system deployment/token-exchange-service --tail=100

# First call:
# "token missing audience echo-tool, attempting exchange"
# "token exchange succeeded for audience=echo-tool"

# Second call (within cache TTL):
# "cache hit for audience=echo-tool"
```

## Related Documentation

- [Extension Provider Scope](extension-provider-scope.md) - Does extension provider impact other projects?
- [Cross-Namespace Communication](cross-namespace-communication.md) - How cross-namespace auth works
- [Token Exchange Service](../cmd/token-exchange-service/README.md) - Service architecture and configuration
- [Operator Design](https://github.com/kagenti/kagenti-operator/blob/main/docs/operator-managed-client-registration.md) - Operator implementation details
- [Main README](../README.md) - Architecture overview and quick start

## Summary

The integration between **kagenti-operator** and **token-exchange-service** provides:

✅ **Automated client lifecycle**: Operator manages Keycloak registration, credentials, and drift reconciliation

✅ **Runtime least-privilege tokens**: Service exchanges tokens on-demand for specific audiences

✅ **Zero per-pod overhead**: No client-registration sidecar needed

✅ **Centralized security policy**: All token validation and exchange in one service

✅ **High performance**: Token caching reduces Keycloak load (>95% cache hit rate in steady state)

✅ **Multi-tenant isolation**: Namespace-scoped secrets and policies ensure isolation

✅ **Separation of concerns**: Platform, security, and application teams work independently

This architecture scales from development (Kind) to production (OpenShift/ROSA) without changing the fundamental security model.
