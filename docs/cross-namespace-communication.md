# Cross-Namespace Communication

This document explains how authorization, token validation, and access control work when agents and tools communicate across namespace boundaries.

## Table of Contents

- [Overview](#overview)
- [Communication Scenarios](#communication-scenarios)
- [Waypoint Placement and Namespace Impact](#waypoint-placement-and-namespace-impact)
- [Token Audience Strategies](#token-audience-strategies)
- [Multi-Namespace Architecture](#multi-namespace-architecture)
- [Configuration Patterns](#configuration-patterns)
- [Best Practices](#best-practices)
- [Troubleshooting](#troubleshooting)

## Overview

The authbridge-waypoint architecture supports **seamless cross-namespace communication** while maintaining namespace isolation and security boundaries.

### Key Principle: Destination-Side Waypoints

Istio waypoints are **strictly destination-side** — they intercept traffic going **TO** services in their namespace, never traffic FROM their namespace.

```
Source Namespace          Destination Namespace
┌──────────────┐         ┌─────────────────────────┐
│              │         │ ┌─────────────────────┐ │
│ Client Pod   │────────▶│ │ Waypoint (L7)       │ │
│              │         │ │ - ext_authz check   │ │
│              │         │ │ - token validation  │ │
│              │         │ │ - token exchange    │ │
│              │         │ └─────────┬───────────┘ │
│              │         │           ▼             │
│              │         │ ┌─────────────────────┐ │
│              │         │ │ Service Pod         │ │
│              │         │ └─────────────────────┘ │
└──────────────┘         └─────────────────────────┘
  No waypoint here!         Waypoint here protects
                            all services in namespace
```

**This means**:
- Source namespace doesn't need a waypoint for outbound calls
- Destination namespace waypoint validates/exchanges tokens
- One waypoint per namespace protects all services in that namespace

## Communication Scenarios

### Scenario 1: Agent → Tool (Different Namespaces)

**This is the primary use case** and works perfectly out of the box.

```
agent-ns                    tool-ns
┌──────────────┐           ┌─────────────────────────┐
│ demo-agent   │           │ tool-waypoint           │
│              │           │  (destination-side)     │
│              │───────────│  ├─ ext_authz           │
│              │           │  │  validate + exchange │
│              │   mTLS    │  ▼                      │
└──────────────┘           │ echo-tool               │
                           └─────────────────────────┘
```

#### Step-by-Step Flow

**1. User obtains token from Keycloak**:
```json
{
  "iss": "https://keycloak.../realms/kagenti",
  "sub": "user-123",
  "aud": ["demo-agent", "token-exchange-service"],
  "azp": "demo-agent",
  "exp": 1234567890
}
```

**2. User calls demo-agent**:
```bash
curl -H "Authorization: Bearer <token>" \
  http://demo-agent.agent-ns.svc.cluster.local/call/echo-tool
```

**3. Agent-ns waypoint (inbound)**:
- Extract destination from request: `demo-agent`
- Check token.aud includes "demo-agent" → **YES**
- Decision: **PASS THROUGH** ✅

**4. Demo-agent forwards to echo-tool**:
```http
GET http://echo-tool.tool-ns.svc.cluster.local/
Authorization: Bearer <original-token>
```

**5. Traffic traverses ztunnel** (mTLS, L4):
- Source: demo-agent.agent-ns
- Destination: echo-tool.tool-ns
- Encrypted via mutual TLS

**6. Tool-ns waypoint (inbound to tool-ns)**:
- Extract destination: `echo-tool.tool-ns.svc.cluster.local` → `echo-tool`
- Check token.aud includes "echo-tool" → **NO**
- Decision: **EXCHANGE** 🔄

**7. Waypoint calls token-exchange-service**:
```
POST token-exchange-service.kagenti-system:9090/Check

CheckRequest:
  - authorization: "Bearer <original-token>"
  - host: "echo-tool.tool-ns.svc.cluster.local"
```

**8. Token-exchange-service performs exchange**:
```
POST https://keycloak.../realms/kagenti/protocol/openid-connect/token

grant_type=urn:ietf:params:oauth:grant-type:token-exchange
subject_token=<original-token>
audience=echo-tool
client_id=token-exchange-service
client_secret=<secret>

Response:
{
  "access_token": "eyJ...",  // New token
  "expires_in": 300
}
```

**9. Waypoint replaces Authorization header**:
```http
GET / HTTP/1.1
Host: echo-tool
Authorization: Bearer <new-token-with-aud-echo-tool>
```

**10. Echo-tool receives**:
```json
{
  "iss": "https://keycloak.../realms/kagenti",
  "sub": "user-123",
  "aud": "echo-tool",
  "azp": "token-exchange-service",
  "exp": 1234567890
}
```

#### Result

✅ **Works perfectly across namespaces**

- Agent and tool in different namespaces
- User identity preserved (`sub: user-123`)
- Token scoped to destination (`aud: echo-tool`)
- Zero configuration in agent code
- All security enforced by waypoints

---

### Scenario 2: Agent → Agent (Different Namespaces)

When one agent calls another agent in a different namespace.

```
namespace-a                 namespace-b
┌──────────────┐           ┌─────────────────────────┐
│ agent-a      │           │ agent-b waypoint        │
│              │───────────│  (destination-side)     │
│              │           │  ├─ ext_authz           │
└──────────────┘           │  │  validate only       │
                           │  ▼                      │
                           │ agent-b                 │
                           └─────────────────────────┘
```

#### How It Works

**1. User obtains token** with **both agents** in audience:
```json
{
  "iss": "https://keycloak.../realms/kagenti",
  "sub": "user-123",
  "aud": ["agent-a", "agent-b", "token-exchange-service"],
  "azp": "agent-a"
}
```

**2. Agent-a forwards request to agent-b**:
```http
GET http://agent-b.namespace-b.svc.cluster.local/some-endpoint
Authorization: Bearer <token>
```

**3. Agent-b waypoint checks**:
- Extract destination: `agent-b`
- Check token.aud includes "agent-b" → **YES**
- Decision: **PASS THROUGH** ✅ (no exchange needed)

**4. Agent-b receives original token**:
```json
{
  "aud": ["agent-a", "agent-b", "token-exchange-service"],
  "sub": "user-123"
}
```

#### Configuration Requirement

The Keycloak client for `agent-a` needs an **audience mapper** that adds `agent-b`:

```bash
# In deploy/03-keycloak-setup.sh or via Keycloak admin UI
AGENT_A_UUID=$(get_client_uuid "agent-a")

curl -X POST "http://keycloak/admin/realms/kagenti/clients/$AGENT_A_UUID/protocol-mappers/models" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "agent-b-audience",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-audience-mapper",
    "config": {
      "included.client.audience": "agent-b",
      "access.token.claim": "true"
    }
  }'
```

#### Result

✅ **Works if token includes both agents**

- Requires pre-configuration in Keycloak
- Token must list all agents user might call
- Less flexible than dynamic exchange
- No token exchange overhead

---

### Scenario 3: Tool → Tool (Chained Calls)

A tool calls another tool, propagating the user's request.

```
agent-ns          tool-ns-1              tool-ns-2
┌────────┐       ┌──────────────┐       ┌──────────────┐
│ agent  │──────▶│ tool-1       │──────▶│ tool-2       │
└────────┘       │ (received    │       │ (received    │
  token with     │  aud=tool-1) │       │  aud=tool-2) │
  aud=agent      └──────────────┘       └──────────────┘
```

#### Challenge

Tool-1 received a token with `aud=tool-1`, but needs to call tool-2.

#### Solution 1: Service Account Token (Recommended)

Tool-1 uses its **own service account token** to call tool-2:

```go
// In tool-1 code
func callTool2(userContext UserContext) (*Response, error) {
    // Get tool-1's own service account token
    // (Kubernetes automatically mounts this at /var/run/secrets/kubernetes.io/serviceaccount/token)
    myToken, err := ioutil.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/token")
    if err != nil {
        return nil, err
    }

    // Call tool-2 with tool-1's token
    req, _ := http.NewRequest("GET", "http://tool-2.tool-ns-2.svc.cluster.local/process", nil)
    req.Header.Set("Authorization", "Bearer " + string(myToken))

    // Optionally: Forward user context in custom headers
    req.Header.Set("X-Original-User", userContext.Sub)
    req.Header.Set("X-Original-Agent", userContext.Azp)

    return http.DefaultClient.Do(req)
}
```

**Flow**:
1. Tool-1 has token with `aud=tool-1`
2. Tool-1 gets its own Kubernetes SA token (or Keycloak service account token)
3. Tool-1 calls tool-2 with its own token
4. Tool-ns-2 waypoint sees token without `aud=tool-2` → exchanges
5. Tool-2 receives exchanged token with `aud=tool-2`

**Advantages**:
- ✅ Works out of the box
- ✅ Each service uses its own identity
- ✅ Clear audit trail (tool-1 called tool-2)

**Disadvantages**:
- ❌ User identity not in token (only in custom headers)
- ❌ Audit shows "tool-1 → tool-2", not "user → tool-2"

#### Solution 2: Multi-Audience Token

If preserving user identity is critical, pre-configure token with all tools:

**Token from Keycloak**:
```json
{
  "aud": ["demo-agent", "tool-1", "tool-2", "token-exchange-service"],
  "sub": "user-123"
}
```

**Flow**:
1. Agent receives token with all audiences
2. Tool-1 receives exchanged token (but original had all audiences)
3. Tool-1 forwards the **original** token (from request context)
4. Tool-ns-2 waypoint sees `aud` includes `tool-2` → passes through
5. Tool-2 receives original token with user identity

**Requires**:
- Configure agent's Keycloak client with audience mappers for all tools
- Agent must store and forward original token (not the exchanged one)

**Advantages**:
- ✅ User identity preserved throughout chain
- ✅ Full audit trail

**Disadvantages**:
- ❌ Token over-privileged (includes all possible tools)
- ❌ Less secure (violates least-privilege)
- ❌ Requires pre-knowledge of all tools

#### Solution 3: Re-exchange via Token Exchange Service

Tool-1 directly calls token-exchange-service to exchange for tool-2:

```go
// In tool-1 code
func callTool2(originalToken string) (*Response, error) {
    // Exchange original token for tool-2 audience
    exchangedToken, err := exchangeToken(originalToken, "tool-2")
    if err != nil {
        return nil, err
    }

    // Call tool-2 with exchanged token
    req, _ := http.NewRequest("GET", "http://tool-2.tool-ns-2.svc.cluster.local/process", nil)
    req.Header.Set("Authorization", "Bearer " + exchangedToken)

    return http.DefaultClient.Do(req)
}

func exchangeToken(subjectToken, audience string) (string, error) {
    resp, err := http.PostForm(
        "http://token-exchange-service.kagenti-system.svc.cluster.local:8080/exchange",
        url.Values{
            "subject_token": {subjectToken},
            "audience":      {audience},
        },
    )
    // Parse response, return access_token
}
```

**Advantages**:
- ✅ User identity preserved
- ✅ Least-privilege tokens
- ✅ Flexible (dynamic audiences)

**Disadvantages**:
- ❌ Requires custom code in tools
- ❌ Token-exchange-service needs HTTP API (not just gRPC)

#### Recommended Approach

For most use cases: **Solution 1 (Service Account Token)**
- Simpler
- Works with standard Kubernetes
- Clear service-to-service identity

For user identity tracking: **Solution 3 (Re-exchange)**
- Preserves user context
- Maintains least-privilege
- Requires HTTP API on token-exchange-service

---

## Waypoint Placement and Namespace Impact

### Waypoint Responsibilities

| Waypoint | Namespace | Protects | Validates |
|----------|-----------|----------|-----------|
| agent-waypoint | agent-ns | Inbound to agents | Tokens going TO agents |
| tool-waypoint | tool-ns | Inbound to tools | Tokens going TO tools |
| egress-gateway | istio-system | Outbound to external | Tokens going TO external services |

**Key insight**: A waypoint in namespace X only sees traffic **going into** namespace X, regardless of source.

### Example: Traffic Flow Across 3 Namespaces

```
┌──────────────────────────────────────────────────────────────┐
│                    kagenti-system                            │
│  ┌────────────────────────────────────────────────────┐      │
│  │   token-exchange-service                           │      │
│  │   (shared by all waypoints)                        │      │
│  └────────────────────────────────────────────────────┘      │
└──────────────────────────────────────────────────────────────┘
         ▲              ▲              ▲              ▲
         │              │              │              │
    ext_authz     ext_authz       ext_authz      ext_authz
         │              │              │              │
┌────────┴───┐  ┌──────┴──────┐ ┌─────┴──────┐ ┌────┴─────────┐
│ agent-ns   │  │ tool-ns-1   │ │ tool-ns-2  │ │ team-a-ns    │
│            │  │             │ │            │ │              │
│ waypoint ◄─┼──┼─────────────┼─┼────────────┼─┼──────────┐   │
│ (inbound)  │  │ waypoint ◄──┼─┼────────────┼─┼────┐     │   │
│     │      │  │ (inbound)   │ │ waypoint ◄─┼─┼──┐ │     │   │
│     ▼      │  │     │       │ │ (inbound)  │ │  │ │     │   │
│ demo-agent │  │     ▼       │ │     │      │ │  │ │     │   │
│     │      │  │ echo-tool   │ │     ▼      │ │  │ │     │   │
│     └──────┼─▶│     │       │ │ time-tool  │ │  │ │     │   │
│            │  │     └───────┼─▶            │ │  │ │     │   │
│            │  │             │ │     │      │ │  │ │     │   │
│            │  │             │ │     └──────┼─┼─▶│ │     │   │
│            │  │             │ │            │ │  │ │     │   │
│            │  │             │ │            │ │  ▼ ▼     ▼   │
│            │  │             │ │            │ │ team-a-api   │
└────────────┘  └─────────────┘ └────────────┘ └──────────────┘
```

**Traffic flow**:
1. User → demo-agent: agent-waypoint validates
2. demo-agent → echo-tool: tool-ns-1 waypoint exchanges
3. echo-tool → time-tool: tool-ns-2 waypoint exchanges
4. time-tool → team-a-api: team-a-ns waypoint exchanges

Each waypoint independently validates/exchanges tokens for its namespace.

## Token Audience Strategies

### Strategy 1: Broad Audience (Simple, Less Secure)

Token includes all potential destinations upfront:

```json
{
  "aud": [
    "demo-agent",
    "echo-tool",
    "time-tool",
    "weather-tool",
    "github-tool",
    "token-exchange-service"
  ],
  "sub": "user-123"
}
```

**Pros**:
- ✅ Token works everywhere without exchange
- ✅ Simple Keycloak configuration
- ✅ No exchange latency

**Cons**:
- ❌ Over-privileged (violates least-privilege)
- ❌ Can't audit which tools were actually used
- ❌ Token compromise gives access to all tools
- ❌ Doesn't scale (need to add every new tool)

**When to use**: Testing, small deployments

### Strategy 2: Dynamic Exchange (Recommended)

Token includes only source + token-exchange-service:

```json
{
  "aud": ["demo-agent", "token-exchange-service"],
  "sub": "user-123"
}
```

Waypoints exchange on-demand:

```
demo-agent → echo-tool: exchange to aud=echo-tool
demo-agent → time-tool: exchange to aud=time-tool
demo-agent → weather-tool: exchange to aud=weather-tool
```

**Pros**:
- ✅ Least-privilege (token scoped per tool)
- ✅ Better auditing (know which tool was accessed)
- ✅ Token compromise limited to one tool per exchange
- ✅ Scales (no need to update for new tools)
- ✅ Works with caching (minimal latency after first call)

**Cons**:
- ❌ Requires Keycloak calls (mitigated by caching)
- ❌ Slightly higher latency (~50ms first call per tool)

**When to use**: Production deployments

### Strategy 3: Hybrid (Agent Groups)

Group related tools and include group audiences:

```json
{
  "aud": [
    "demo-agent",
    "internal-tools",  // Group for echo, time, etc.
    "external-apis",   // Group for github, weather, etc.
    "token-exchange-service"
  ],
  "sub": "user-123"
}
```

**Requires**: Custom logic in token-exchange-service to map groups to tools

**Pros**:
- ✅ Balance between security and performance
- ✅ Reasonable privilege scope

**Cons**:
- ❌ More complex configuration
- ❌ Custom code needed

**When to use**: Large deployments with clear tool groupings

### Comparison

| Strategy | Security | Performance | Scalability | Complexity |
|----------|----------|-------------|-------------|------------|
| **Broad Audience** | 🔴 Low | 🟢 High | 🔴 Low | 🟢 Low |
| **Dynamic Exchange** | 🟢 High | 🟡 Medium | 🟢 High | 🟡 Medium |
| **Hybrid** | 🟡 Medium | 🟡 Medium | 🟡 Medium | 🔴 High |

**Recommendation**: Use **Dynamic Exchange** (Strategy 2) for production.

## Multi-Namespace Architecture

### Pattern 1: Namespace per Team

```
team-a-ns
├── team-a-api
├── team-a-worker
└── waypoint (protects all team-a services)

team-b-ns
├── team-b-api
├── team-b-processor
└── waypoint (protects all team-b services)

shared-tools-ns
├── echo-tool
├── time-tool
└── waypoint (protects all shared tools)
```

**Configuration**:
```yaml
# Each namespace has its own policy
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: team-a-auth
  namespace: team-a-ns
spec:
  action: CUSTOM
  provider:
    name: kagenti-token-exchange
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: team-b-auth
  namespace: team-b-ns
spec:
  action: CUSTOM
  provider:
    name: kagenti-token-exchange
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: shared-tools-auth
  namespace: shared-tools-ns
spec:
  action: CUSTOM
  provider:
    name: kagenti-token-exchange
```

**Advantages**:
- ✅ Clear team boundaries
- ✅ Independent policies
- ✅ Easy RBAC (team owns namespace)

### Pattern 2: Namespace per Environment

```
production-ns
├── agent
├── tool-1
├── tool-2
└── waypoint

staging-ns
├── agent
├── tool-1
├── tool-2
└── waypoint

development-ns
├── agent
├── tool-1
├── tool-2
└── waypoint
```

**Advantages**:
- ✅ Environment isolation
- ✅ Same structure across environments
- ✅ Easy promotion (same manifests)

### Pattern 3: Shared Agents, Isolated Tools

```
agent-ns (shared)
├── agent-a
├── agent-b
└── waypoint

tool-team-a-ns
├── tool-a1
├── tool-a2
└── waypoint

tool-team-b-ns
├── tool-b1
├── tool-b2
└── waypoint
```

**Advantages**:
- ✅ Agents can call any team's tools
- ✅ Tools isolated by team
- ✅ Flexible routing

## Configuration Patterns

### Complete Multi-Namespace Setup

**Prerequisites**:
```bash
# 1. Configure Istio extension provider (once)
make config

# 2. Create namespaces
kubectl create namespace agent-ns
kubectl create namespace tool-ns-internal
kubectl create namespace tool-ns-external

# 3. Label namespaces for ambient mesh
kubectl label namespace agent-ns istio.io/dataplane-mode=ambient
kubectl label namespace tool-ns-internal istio.io/dataplane-mode=ambient
kubectl label namespace tool-ns-external istio.io/dataplane-mode=ambient
```

**Deploy waypoints**:
```bash
# agent-ns waypoint
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: agent-waypoint
  namespace: agent-ns
  labels:
    istio.io/waypoint-for: all
spec:
  gatewayClassName: istio-waypoint
  listeners:
  - name: mesh
    port: 15008
    protocol: HBONE
EOF

# tool-ns-internal waypoint
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: internal-tools-waypoint
  namespace: tool-ns-internal
  labels:
    istio.io/waypoint-for: service
spec:
  gatewayClassName: istio-waypoint
  listeners:
  - name: mesh
    port: 15008
    protocol: HBONE
EOF

# tool-ns-external waypoint
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: external-tools-waypoint
  namespace: tool-ns-external
  labels:
    istio.io/waypoint-for: service
spec:
  gatewayClassName: istio-waypoint
  listeners:
  - name: mesh
    port: 15008
    protocol: HBONE
EOF
```

**Deploy policies** (all reference same provider):
```bash
for ns in agent-ns tool-ns-internal tool-ns-external; do
  kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: kagenti-token-exchange
  namespace: $ns
spec:
  action: CUSTOM
  provider:
    name: kagenti-token-exchange
  rules:
  - to:
    - operation:
        notPaths:
        - "/.well-known/*"
        - "/healthz"
        - "/readyz"
        - "/livez"
EOF
done
```

**Deploy services**:
```bash
# Agents in agent-ns
kubectl apply -f deploy/08-workloads.yaml

# Tools in tool-ns-internal
kubectl apply -n tool-ns-internal -f my-tools.yaml

# External API proxies in tool-ns-external
kubectl apply -n tool-ns-external -f external-apis.yaml
```

## Best Practices

### 1. One Waypoint per Namespace

**Do this**:
```
namespace-a
└── waypoint-a (protects all services in namespace-a)

namespace-b
└── waypoint-b (protects all services in namespace-b)
```

**Not this**:
```
namespace-a
├── waypoint-for-service-1
├── waypoint-for-service-2
└── waypoint-for-service-3
```

**Rationale**: Simpler, fewer resources, easier to manage

### 2. Use Consistent Naming

```yaml
# Good: Predictable names
metadata:
  name: kagenti-token-exchange
  namespace: tool-ns

# Bad: Inconsistent
metadata:
  name: my-custom-auth-policy-v2
  namespace: tool-ns
```

### 3. Document Cross-Namespace Dependencies

```yaml
# In agent deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-agent
  namespace: agent-ns
  annotations:
    kagenti.io/calls-namespaces: "tool-ns-internal,tool-ns-external"
    kagenti.io/token-strategy: "dynamic-exchange"
```

### 4. Test Cross-Namespace Communication

```bash
# Test script
#!/bin/bash

echo "=== Testing Cross-Namespace Communication ==="

# Get token
TOKEN=$(curl -sf -X POST "$KC_URL/realms/kagenti/protocol/openid-connect/token" \
  -d "grant_type=client_credentials&client_id=demo-agent&client_secret=agent-secret" | \
  jq -r '.access_token')

# Test agent → internal tool
echo "Testing agent-ns → tool-ns-internal"
kubectl run test -n agent-ns --rm -i --image=curlimages/curl -- \
  curl -H "Authorization: Bearer $TOKEN" \
  http://echo-tool.tool-ns-internal.svc.cluster.local/

# Test agent → external tool
echo "Testing agent-ns → tool-ns-external"
kubectl run test -n agent-ns --rm -i --image=curlimages/curl -- \
  curl -H "Authorization: Bearer $TOKEN" \
  http://github-tool.tool-ns-external.svc.cluster.local/

echo "=== Tests complete ==="
```

### 5. Monitor Cross-Namespace Traffic

```bash
# Check which namespaces are calling each other
kubectl logs -n kagenti-system -l app=token-exchange-service | \
  awk '/exchange/{print}' | \
  # Parse source namespace, destination namespace, tool
  awk '{print $X" → "$Y}' | \
  sort | uniq -c

# Example output:
# 150 agent-ns → tool-ns-internal/echo-tool
#  75 agent-ns → tool-ns-external/github-tool
#  20 tool-ns-internal/orchestrator → tool-ns-external/weather-tool
```

## Troubleshooting

### Problem: Cross-namespace calls fail with 401

**Symptoms**:
```json
{
  "error": "invalid token: token is malformed"
}
```

**Check**:
```bash
# 1. Verify waypoint exists in destination namespace
kubectl get gateway -n <dest-namespace>

# 2. Verify policy exists
kubectl get authorizationpolicy -n <dest-namespace>

# 3. Check token-exchange-service logs
kubectl logs -n kagenti-system -l app=token-exchange-service --tail=50

# 4. Verify token includes token-exchange-service in aud
echo $TOKEN | cut -d. -f2 | base64 -d | jq .aud
# Should include "token-exchange-service"
```

### Problem: Token exchange fails

**Symptoms**:
```json
{
  "error": "token exchange failed: token exchange returned 400: {\"error\":\"invalid_request\"}"
}
```

**Solutions**:
```bash
# 1. Check Keycloak setup
bash deploy/03-keycloak-setup.sh

# 2. Verify standard.token.exchange.enabled on token-exchange-service client

# 3. Check token-exchange-service has correct audience mapper
```

### Problem: Waypoint not intercepting traffic

**Symptoms**: Traffic bypasses waypoint, no token exchange occurs

**Check**:
```bash
# 1. Verify namespace has ambient label
kubectl get namespace <ns> -o yaml | grep istio.io/dataplane-mode
# Should show: istio.io/dataplane-mode: ambient

# 2. Verify waypoint is serving
kubectl get gateway <waypoint-name> -n <ns> -o yaml

# 3. Check waypoint pods are running
kubectl get pods -n <ns> -l istio.io/gateway-name=<waypoint-name>

# 4. Verify service has waypoint annotation
kubectl get svc <service> -n <ns> -o yaml | grep waypoint
```

### Problem: High latency on cross-namespace calls

**Diagnosis**:
```bash
# Check token cache hit rate
kubectl logs -n kagenti-system -l app=token-exchange-service | \
  grep -c "using cached token"

# Check Keycloak response time
kubectl logs -n keycloak -l app=keycloak | grep token-exchange

# Check if JWKS cache is working
kubectl logs -n kagenti-system -l app=token-exchange-service | \
  grep "JWKS"
```

**Solutions**:
- Verify caching is working (should see "using cached token")
- Check Keycloak isn't overloaded
- Consider increasing token TTL in Keycloak

## Summary

### Key Takeaways

1. **Cross-namespace communication works seamlessly**
   - Waypoints are destination-side
   - Source namespace doesn't need special configuration
   - Destination waypoint handles validation/exchange

2. **Flexible token strategies**
   - Dynamic exchange (recommended): least-privilege
   - Broad audience: simpler but less secure
   - Hybrid: balanced approach

3. **Architecture scales**
   - One token-exchange-service for entire cluster
   - One waypoint per namespace
   - Independent policies per namespace

4. **Best practices**
   - Use dynamic exchange for security
   - One waypoint per namespace for simplicity
   - Test cross-namespace flows
   - Monitor token exchange patterns

### Decision Matrix

| Use Case | Recommended Pattern |
|----------|-------------------|
| Agent → Tool (different NS) | Dynamic exchange |
| Agent → Agent (different NS) | Multi-audience token |
| Tool → Tool chaining | Service account tokens |
| Multi-team cluster | Namespace per team |
| Multi-environment | Namespace per environment |

### Related Documentation

- [Extension Provider Scope](extension-provider-scope.md)
- [Token Exchange Service](../cmd/token-exchange-service/README.md)
- [Main README](../README.md)
