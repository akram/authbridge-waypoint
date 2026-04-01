# Architecture Deep Dive: AuthBridge Waypoint

> **A comprehensive guide to understanding how AuthBridge Waypoint provides zero-trust service-to-service authentication in Kubernetes**

This document provides a "deep dive but brief" explanation of every component in the AuthBridge Waypoint architecture, how they install, what they do, and how they communicate with each other.

## Table of Contents

- [Executive Summary](#executive-summary)
- [The Problem We're Solving](#the-problem-were-solving)
- [Solution Architecture Overview](#solution-architecture-overview)
- [Core Components Deep Dive](#core-components-deep-dive)
  - [Kubernetes](#1-kubernetes)
  - [Istio Ambient Mesh](#2-istio-ambient-mesh)
  - [ztunnel (Zero Trust Tunnel)](#3-ztunnel-zero-trust-tunnel)
  - [Waypoint Proxy](#4-waypoint-proxy)
  - [Istio Extension Provider](#5-istio-extension-provider)
  - [Keycloak](#6-keycloak)
  - [token-exchange-service](#7-token-exchange-service)
  - [kagenti-operator](#8-kagenti-operator)
  - [AuthorizationPolicy](#9-authorizationpolicy)
  - [RFC 8693 Token Exchange](#10-rfc-8693-token-exchange)
  - [JWT and JWKS](#11-jwt-and-jwks)
- [How Components Communicate](#how-components-communicate)
- [Complete Request Lifecycle](#complete-request-lifecycle)
- [Installation and Deployment](#installation-and-deployment)
- [Benefits and Trade-offs](#benefits-and-trade-offs)
- [Comparison with Traditional Approaches](#comparison-with-traditional-approaches)

---

## Executive Summary

**AuthBridge Waypoint** is a zero-trust authentication and authorization system for Kubernetes that provides:

- ✅ **Automatic JWT validation** for every service-to-service call
- ✅ **Dynamic token exchange** for least-privilege access tokens
- ✅ **Zero application code changes** required
- ✅ **No per-pod sidecars** (uses Istio ambient mesh waypoints)
- ✅ **Centralized security policy** enforcement
- ✅ **Operator-managed client lifecycle** in Keycloak

**In plain English**: Every time one service calls another, their traffic is automatically routed through a security checkpoint that validates their identity (JWT), checks if they're allowed to communicate, and if needed, exchanges their access token for one specific to the destination service—all without the application knowing or caring.

---

## The Problem We're Solving

### Traditional Microservices Security Challenges

```
┌─────────────────────────────────────────────────────────────┐
│                    BEFORE: Security Gaps                    │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Service A ──────────────────────────► Service B            │
│    (no authentication check)                                │
│                                                             │
│  Problems:                                                  │
│  ❌ Service B doesn't know who's calling                    │
│  ❌ No validation of caller's identity                      │
│  ❌ Broad access tokens (one token for everything)          │
│  ❌ Application code must handle auth logic                 │
│  ❌ Inconsistent security across services                   │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                   AFTER: Zero-Trust Security                │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Service A ───► Waypoint ───► token-exchange ───► Service B │
│                   │              │                           │
│                   ├─ Validate JWT                           │
│                   ├─ Check audience                         │
│                   └─ Exchange token if needed               │
│                                                             │
│  Benefits:                                                  │
│  ✅ Every call is authenticated                             │
│  ✅ Least-privilege tokens (audience-scoped)                │
│  ✅ Zero application code changes                           │
│  ✅ Centralized security policy                             │
│  ✅ Automatic credential rotation                           │
└─────────────────────────────────────────────────────────────┘
```

---

## Solution Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────────┐
│                          KUBERNETES CLUSTER                              │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────┐    │
│  │                    ISTIO AMBIENT MESH                          │    │
│  │                                                                │    │
│  │  ┌──────────┐                                  ┌──────────┐   │    │
│  │  │ ztunnel  │◄────────────────────────────────►│ ztunnel  │   │    │
│  │  │ (node 1) │       mTLS encrypted traffic     │ (node 2) │   │    │
│  │  └──────────┘                                  └──────────┘   │    │
│  │       ▲                                              ▲        │    │
│  │       │                                              │        │    │
│  └───────┼──────────────────────────────────────────────┼────────┘    │
│          │                                              │             │
│  ┌───────┴─────────┐                           ┌────────┴──────────┐  │
│  │  Namespace: A   │                           │  Namespace: B     │  │
│  │                 │                           │                   │  │
│  │  ┌──────────┐   │                           │   ┌──────────┐   │  │
│  │  │ Service A│───┼───────────────────────────┼──►│ Service B│   │  │
│  │  │  (pod)   │   │         HTTP call         │   │  (pod)   │   │  │
│  │  └──────────┘   │                           │   └──────────┘   │  │
│  │                 │                           │         ▲        │  │
│  │                 │                           │         │        │  │
│  │                 │                           │   ┌─────┴─────┐  │  │
│  │                 │                           │   │ Waypoint  │  │  │
│  │                 │                           │   │  Proxy    │  │  │
│  │                 │                           │   └─────┬─────┘  │  │
│  │                 │                           │         │        │  │
│  └─────────────────┘                           └─────────┼────────┘  │
│                                                          │           │
│  ┌──────────────────────────────────────────────────────┼─────────┐ │
│  │              kagenti-system namespace                │         │ │
│  │                                                       ▼         │ │
│  │  ┌────────────────────────────────────────────────────────┐   │ │
│  │  │         token-exchange-service                         │   │ │
│  │  │  ┌──────────────────┐    ┌──────────────────┐          │   │ │
│  │  │  │ ext_authz gRPC   │    │ JWT Validation   │          │   │ │
│  │  │  │ (from waypoint)  │───►│ Token Exchange   │          │   │ │
│  │  │  └──────────────────┘    └──────────────────┘          │   │ │
│  │  └──────────────┬─────────────────────────────────────────┘   │ │
│  │                 │                                              │ │
│  │  ┌──────────────┴─────────────────┐                           │ │
│  │  │    kagenti-operator            │                           │ │
│  │  │  (client registration)         │                           │ │
│  │  └──────────────┬─────────────────┘                           │ │
│  └─────────────────┼──────────────────────────────────────────────┘ │
│                    │                                                │
└────────────────────┼────────────────────────────────────────────────┘
                     │
          ┌──────────┴──────────┐
          │     Keycloak        │
          │  (Identity Provider)│
          │  - User auth        │
          │  - Client registry  │
          │  - Token issuance   │
          │  - Token exchange   │
          └─────────────────────┘
```

---

## Core Components Deep Dive

### 1. Kubernetes

**What it does:**
- Container orchestration platform
- Runs and manages applications in "pods" (groups of containers)
- Provides networking, storage, and scheduling

**How it installs:**
- Managed service (EKS, GKE, OpenShift) or self-hosted (kubeadm, Kind)
- For development: Kind (Kubernetes IN Docker) creates a local cluster
- For production: ROSA (Red Hat OpenShift on AWS), EKS, etc.

**What it allows:**
- Deploy microservices as containers
- Service discovery via DNS (`service-name.namespace.svc.cluster.local`)
- Network policies, secrets, config maps

**In this architecture:**
- Base platform that runs all other components
- Provides namespaces for isolation (agent-ns, tool-ns, kagenti-system)

---

### 2. Istio Ambient Mesh

**What it does:**
- Service mesh that manages service-to-service communication
- "Ambient" mode = no sidecars in application pods
- Provides mTLS encryption, traffic routing, observability

**How it installs:**
```bash
# Install Istio with ambient profile
istioctl install --set profile=ambient

# Creates:
# - istiod (control plane) in istio-system namespace
# - ztunnel DaemonSet (one per node)
# - CNI plugin for traffic interception
```

**What it allows:**
- Automatic mTLS between services (encryption in transit)
- Traffic management (retries, timeouts, circuit breakers)
- Observability (metrics, traces, logs)
- Security policies (authorization, authentication)

**Architecture layers:**
```
┌──────────────────────────────────────┐
│  Layer 7 (HTTP/gRPC)                 │
│  - Waypoint proxy (optional, L7)    │◄─ AuthBridge uses this
│  - Rich policies (auth, routing)    │
└──────────────────────────────────────┘
┌──────────────────────────────────────┐
│  Layer 4 (TCP)                       │
│  - ztunnel (mandatory, per-node)    │
│  - mTLS encryption                   │
└──────────────────────────────────────┘
┌──────────────────────────────────────┐
│  Application Pods                    │
│  - No sidecar needed!                │
└──────────────────────────────────────┘
```

**In this architecture:**
- Provides the foundation for traffic interception
- ztunnel encrypts traffic between nodes
- Waypoint proxies handle L7 authorization

---

### 3. ztunnel (Zero Trust Tunnel)

**What it does:**
- Node-level proxy that runs on every Kubernetes node
- Implements "secure overlay" network for pod-to-pod communication
- Enforces mTLS encryption at Layer 4 (TCP)

**How it installs:**
```bash
# Installed automatically with Istio ambient profile
# Deployed as a DaemonSet (one pod per node)

kubectl get pods -n istio-system -l app=ztunnel
# NAME            READY   STATUS    NODE
# ztunnel-abc123  1/1     Running   node-1
# ztunnel-def456  1/1     Running   node-2
```

**What it allows:**
- Transparent mTLS encryption (pods don't need TLS certificates)
- Identity-based authentication using SPIFFE IDs
- Network-level security without application changes

**How it works:**
```
Pod A (10.1.1.10) wants to call Pod B (10.1.2.20)

1. Pod A sends HTTP request to Pod B
   └─► Traffic intercepted by iptables (Istio CNI)

2. Traffic routed to ztunnel on node-1
   ztunnel encrypts with mTLS:
     - Source identity: spiffe://cluster.local/ns/ns-a/sa/sa-a
     - Dest identity: spiffe://cluster.local/ns/ns-b/sa/sa-b

3. Encrypted traffic sent to ztunnel on node-2

4. ztunnel on node-2 decrypts and validates identity

5. Traffic delivered to Pod B
```

**In this architecture:**
- Provides encrypted transport layer
- Does NOT handle Layer 7 (HTTP) authorization
- Passes HTTP traffic to waypoint proxies for policy enforcement

---

### 4. Waypoint Proxy

**What it does:**
- Layer 7 (HTTP/gRPC) proxy for advanced traffic management
- Deployed per namespace (or per service account)
- Handles HTTP-aware policies: routing, retries, authorization

**How it installs:**
```bash
# Deploy waypoint proxy for a namespace
istioctl waypoint apply --namespace=tool-ns

# Creates a Deployment in the namespace:
# - Name: waypoint
# - Runs Envoy proxy
# - Listens on internal address
```

**What it allows:**
- HTTP header manipulation
- Advanced routing (path-based, header-based)
- **ext_authz integration** ← KEY for AuthBridge
- Metrics and tracing at HTTP level

**Placement strategy:**
```
DESTINATION-SIDE WAYPOINT (this architecture uses this)
┌─────────┐                  ┌─────────────┐
│ Agent   │─────────────────►│  Waypoint   │
│ (ns-a)  │  HTTP request    │  (ns-b)     │
└─────────┘                  └──────┬──────┘
                                    │
                                    ▼
                             ┌─────────────┐
                             │   Tool      │
                             │   (ns-b)    │
                             └─────────────┘

Why destination-side?
- Tool namespace controls its own security policy
- Authorization happens before traffic reaches the tool
- Tool owner decides who can call them
```

**In this architecture:**
- One waypoint per namespace that needs authorization
- Waypoint intercepts inbound HTTP traffic
- Calls token-exchange-service via ext_authz
- Adds/modifies Authorization header before forwarding to tool

---

### 5. Istio Extension Provider

**What it does:**
- Configures external authorization services for Istio
- Defines gRPC endpoint for ext_authz (external authorization) calls
- Registered cluster-wide but activated per-namespace

**How it installs:**
```bash
# Patch Istio ConfigMap to add extension provider
kubectl patch cm istio -n istio-system --type=merge -p '
data:
  mesh: |
    extensionProviders:
    - name: kagenti-token-exchange
      envoyExtAuthzGrpc:
        service: token-exchange-service.kagenti-system.svc.cluster.local
        port: 9090
'

# Restart istiod to pick up changes
kubectl rollout restart deployment/istiod -n istio-system
```

**What it allows:**
- Delegate authorization decisions to external service
- Centralized auth logic (not in every waypoint)
- Consistent policy enforcement across the mesh

**ext_authz Protocol:**
```
Waypoint Proxy ──────────► token-exchange-service
                gRPC call

Request (CheckRequest proto):
{
  "attributes": {
    "request": {
      "http": {
        "method": "GET",
        "path": "/echo",
        "headers": {
          "authorization": "Bearer <JWT>",
          ":authority": "echo-tool.tool-ns.svc.cluster.local"
        }
      }
    }
  }
}

Response (CheckResponse proto):
{
  "status": { "code": 0 },  // OK
  "okResponse": {
    "headers": [
      {
        "header": {
          "key": "authorization",
          "value": "Bearer <EXCHANGED_JWT>"  // ← Modified token
        }
      }
    ]
  }
}
```

**In this architecture:**
- Extension provider points to token-exchange-service
- Every waypoint can reference this provider
- No code duplication (one service handles all auth)

---

### 6. Keycloak

**What it does:**
- Identity and Access Management (IAM) system
- Manages users, clients (services), and tokens
- Implements OAuth 2.0, OpenID Connect, and SAML

**How it installs:**
```bash
# Helm chart installation
helm install keycloak bitnami/keycloak \
  --set auth.adminUser=admin \
  --set auth.adminPassword=<password> \
  --namespace keycloak

# Creates:
# - Keycloak StatefulSet
# - PostgreSQL database
# - Service and Route/Ingress
```

**What it allows:**
- User authentication (login with username/password, SSO)
- OAuth client registration (each service is a client)
- JWT token issuance with custom claims (aud, azp, sub)
- **RFC 8693 token exchange** (key feature for this architecture)

**Keycloak Concepts:**

| Concept | Description | Example |
|---------|-------------|---------|
| **Realm** | Isolated domain for users and clients | `kagenti` |
| **Client** | Service or application that uses Keycloak | `agent-ns/demo-agent`, `echo-tool` |
| **User** | Human or service account | `alice`, `bob` |
| **Client Credentials** | client_id + client_secret for auth | `echo-tool` / `abc123secret` |
| **JWT** | JSON Web Token (access token) | `eyJhbGc...` (base64-encoded JSON) |
| **Audience (aud)** | Who the token is intended for | `["echo-tool", "token-exchange-service"]` |

**Token Structure:**
```json
{
  "iss": "https://keycloak.example.com/realms/kagenti",
  "sub": "user-alice",
  "azp": "agent-ns/demo-agent",  // Authorized party (who got the token)
  "aud": [                        // Audience (who can use it)
    "agent-ns/demo-agent",
    "token-exchange-service"
  ],
  "exp": 1234567890,              // Expiration timestamp
  "iat": 1234567800,              // Issued at
  "client_id": "agent-ns/demo-agent"
}
```

**In this architecture:**
- Central authority for all identities
- Issues JWTs when users/services authenticate
- Performs token exchange when called by token-exchange-service
- Stores client credentials (managed by kagenti-operator)

---

### 7. token-exchange-service

**What it does:**
- Validates JWTs (signature, expiration, issuer)
- Checks if token audience matches destination service
- Performs RFC 8693 token exchange if needed
- Caches exchanged tokens for performance

**How it installs:**
```bash
# Build and deploy
make images        # Build container image
make deploy-core   # Deploy to kagenti-system namespace

# Creates:
# - Deployment: token-exchange-service
# - Service: token-exchange-service (port 9090 for gRPC, 8080 for HTTP proxy)
# - ConfigMap: with Keycloak URL, realm
# - Secret: with CLIENT_SECRET
```

**Configuration:**
```yaml
env:
- name: KEYCLOAK_URL
  value: "http://keycloak-service.keycloak.svc:8080"
- name: ISSUER_URL
  value: "https://keycloak.example.com/realms/kagenti"  # External URL in JWT
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

**What it allows:**
- **Dual interface**:
  1. **gRPC ext_authz**: Called by Istio waypoints
  2. **HTTP forward proxy**: Called via `HTTP_PROXY` env var (for non-mesh workloads)
- Centralized authorization logic
- Token caching (avoids repeated Keycloak calls)

**Authorization Decision Logic:**
```go
func evaluateAuth(authHeader, host, reqPath string) Decision {
    // 1. Extract JWT from Authorization: Bearer <token>
    token := extractBearer(authHeader)

    // 2. Validate JWT signature using JWKS from Keycloak
    claims := validateJWT(token)

    // 3. Derive destination audience from hostname
    // "echo-tool.tool-ns.svc.cluster.local" → "echo-tool"
    audience := extractServiceName(host)

    // 4. Check if token already has the right audience
    if claims.hasAudience(audience) {
        return ALLOW  // Pass through with original token
    }

    // 5. Check cache (key = hash(token + audience))
    if cached := cache.get(token, audience); cached != nil {
        return ALLOW_WITH_TOKEN(cached)  // Use cached exchanged token
    }

    // 6. Call Keycloak to exchange token
    exchangedToken := exchangeToken(token, audience)
    cache.set(token, audience, exchangedToken)

    return ALLOW_WITH_TOKEN(exchangedToken)  // Use new exchanged token
}
```

**Caching Strategy:**
```
JWKS Cache (public keys):
  - Refreshed every 15 minutes
  - Used to validate JWT signatures
  - Avoids fetching keys on every request

Token Cache (exchanged tokens):
  - Key: SHA256(original_token + audience)
  - TTL: token.exp - 30 seconds (safety margin)
  - Typical hit rate: >95% in steady state

Example:
  First call to echo-tool:  CACHE MISS → Keycloak exchange (~100ms)
  Second call:              CACHE HIT  → Return cached token (<1ms)
  Third call (same user):   CACHE HIT  → Return cached token (<1ms)
```

**In this architecture:**
- Single shared service in kagenti-system namespace
- Serves all waypoints cluster-wide
- Talks to Keycloak for token exchange
- No per-pod overhead (replaces token-exchange sidecars)

---

### 8. kagenti-operator

**What it does:**
- Kubernetes operator that watches Deployments/StatefulSets
- Automatically registers workloads as OAuth clients in Keycloak
- Provisions client credentials as Kubernetes Secrets
- Reconciles drift (updates clients when configuration changes)

**How it installs:**
```bash
# Deploy operator to kagenti-operator-system namespace
kubectl apply -f operator.yaml

# Creates:
# - Deployment: kagenti-operator
# - ClusterRole + ClusterRoleBinding (RBAC)
# - CRDs (if using custom resources)
```

**What it allows:**
- **Operator-managed client registration** (no sidecar needed)
- Deterministic secret naming: `kagenti-keycloak-client-credentials-<hash>`
- Automatic credential rotation and drift reconciliation
- Integration with kagenti-webhook for secret mounting

**Reconciliation Flow:**
```
1. Watch for Deployments/StatefulSets with label:
   kagenti.io/type=agent|tool
   kagenti.io/client-registration-inject != "true"

2. For each workload:
   a. Read authbridge-config ConfigMap (namespace-scoped)
   b. Read keycloak-admin-secret Secret (namespace-scoped)
   c. Compute client ID:
      - Without SPIRE: namespace/workloadName
      - With SPIRE: spiffe://<trust-domain>/ns/<ns>/sa/<sa>
   d. Call Keycloak admin API:
      POST /admin/realms/{realm}/clients
      {
        "clientId": "tool-ns/echo-tool",
        "attributes": {
          "standard.token.exchange.enabled": "true"  ← CRITICAL
        }
      }
   e. Create Secret with client-id.txt and client-secret.txt
   f. Patch pod template annotation:
      kagenti.io/keycloak-client-credentials-secret-name: <secret-name>

3. kagenti-webhook sees annotation → mounts Secret to /shared/
```

**Client Registration in Keycloak:**
```
Admin API Call (operator → Keycloak):

POST /admin/realms/kagenti/clients
Authorization: Bearer <admin-token>
{
  "clientId": "tool-ns/echo-tool",
  "name": "echo-tool",
  "clientAuthenticatorType": "client-secret",
  "serviceAccountsEnabled": true,
  "directAccessGrantsEnabled": true,
  "attributes": {
    "standard.token.exchange.enabled": "true"  ← Allows this client as audience
  }
}

Response:
{
  "id": "abc-123-uuid",  // Internal Keycloak UUID
  "clientId": "tool-ns/echo-tool",
  "secret": "def456secret"  ← Generated by Keycloak
}

Operator creates Secret:
apiVersion: v1
kind: Secret
metadata:
  name: kagenti-keycloak-client-credentials-abc123
  namespace: tool-ns
  ownerReferences:
  - apiVersion: apps/v1
    kind: Deployment
    name: echo-tool
data:
  client-id.txt: dG9vbC1ucy9lY2hvLXRvb2w=       # base64("tool-ns/echo-tool")
  client-secret.txt: ZGVmNDU2c2VjcmV0           # base64("def456secret")
```

**In this architecture:**
- Eliminates manual client registration in Keycloak
- Ensures all workloads have `standard.token.exchange.enabled=true`
- Provides consistent secret naming and mounting
- Works with kagenti-webhook for credential injection

---

### 9. AuthorizationPolicy

**What it does:**
- Kubernetes custom resource (Istio API)
- Activates ext_authz for specific namespaces/workloads
- References the extension provider (kagenti-token-exchange)

**How it installs:**
```bash
# Apply to a namespace to enable authorization
kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: tool-waypoint-token-exchange
  namespace: tool-ns
spec:
  action: CUSTOM
  provider:
    name: kagenti-token-exchange  # ← References extension provider
  rules:
  - to:
    - operation:
        notPaths:  # Bypass paths (no auth required)
        - "/.well-known/*"
        - "/healthz"
        - "/readyz"
EOF
```

**What it allows:**
- Per-namespace activation of ext_authz
- Bypass certain paths (health checks, well-known endpoints)
- Multiple policies can coexist (AND logic)

**Policy Scoping:**
```
Extension Provider (cluster-wide):
  Registered in istio ConfigMap
  Available to ALL namespaces
  Zero impact until activated

AuthorizationPolicy (namespace-scoped):
  Created in specific namespace
  ONLY affects traffic in that namespace
  Activates the extension provider

Example:
┌────────────────────────────────────────┐
│ istio-system namespace                 │
│ extensionProviders:                    │
│ - kagenti-token-exchange ←─────────────┼── Global registration
└────────────────────────────────────────┘
         │                │
         ├────────────────┼────────────────┐
         ▼                ▼                ▼
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│ tool-ns      │  │ agent-ns     │  │ other-ns     │
│              │  │              │  │              │
│ AuthPolicy ✅ │  │ AuthPolicy ✅ │  │ (no policy)  │
│ → protected  │  │ → protected  │  │ → unaffected │
└──────────────┘  └──────────────┘  └──────────────┘
```

**In this architecture:**
- One AuthorizationPolicy per namespace that needs protection
- All policies reference the same extension provider
- Waypoint enforces the policy before routing to pods

---

### 10. RFC 8693 Token Exchange

**What it does:**
- OAuth 2.0 extension for exchanging one token for another
- Enables "token narrowing" (broader token → narrower token)
- Preserves original subject (user identity)

**How it works:**
```
Request to Keycloak:
POST /realms/kagenti/protocol/openid-connect/token
Content-Type: application/x-www-form-urlencoded

grant_type=urn:ietf:params:oauth:grant-type:token-exchange
&subject_token=<ORIGINAL_JWT>
&subject_token_type=urn:ietf:params:oauth:token-type:access_token
&audience=echo-tool
&client_id=token-exchange-service
&client_secret=<SERVICE_SECRET>

Response:
{
  "access_token": "<NEW_JWT>",  ← Token with aud=["echo-tool"]
  "issued_token_type": "urn:ietf:params:oauth:token-type:access_token",
  "token_type": "Bearer",
  "expires_in": 300
}
```

**Token Transformation:**
```
BEFORE (original token):
{
  "iss": "https://keycloak.example.com/realms/kagenti",
  "sub": "user-alice",                      ← User identity
  "azp": "agent-ns/demo-agent",             ← Issued to agent
  "aud": [
    "agent-ns/demo-agent",
    "token-exchange-service"
  ],
  "exp": 1234567890
}

AFTER (exchanged token):
{
  "iss": "https://keycloak.example.com/realms/kagenti",
  "sub": "user-alice",                      ← SAME user (preserved)
  "azp": "token-exchange-service",          ← Issued by exchange service
  "aud": ["echo-tool"],                     ← NEW audience (narrowed)
  "exp": 1234567890                         ← Shorter expiry (security)
}
```

**Why it's needed:**
- **Least-privilege principle**: Each service gets a token specific to its needs
- **Token narrowing**: Broad token → narrow token
- **Auditability**: Know which user initiated the call chain
- **Security**: Stolen token can't be used for unintended services

**In this architecture:**
- token-exchange-service calls Keycloak RFC 8693 endpoint
- Authenticates as "token-exchange-service" client
- Requests token for target audience (e.g., "echo-tool")
- Keycloak validates permissions and issues new token

---

### 11. JWT and JWKS

**What it does:**
- **JWT (JSON Web Token)**: Signed JSON payload for authentication
- **JWKS (JSON Web Key Set)**: Public keys for verifying JWT signatures

**JWT Structure:**
```
JWT = <header>.<payload>.<signature>

Header (base64-encoded JSON):
{
  "alg": "RS256",  // Algorithm: RSA with SHA-256
  "typ": "JWT",
  "kid": "abc123"  // Key ID (matches JWKS)
}

Payload (base64-encoded JSON):
{
  "iss": "https://keycloak.example.com/realms/kagenti",
  "sub": "user-alice",
  "aud": ["echo-tool"],
  "exp": 1234567890,
  "iat": 1234567800,
  "azp": "agent-ns/demo-agent",
  "client_id": "agent-ns/demo-agent"
}

Signature (RSA signature of header + payload):
<binary data, base64-encoded>
```

**JWKS (Public Keys):**
```
GET https://keycloak.example.com/realms/kagenti/protocol/openid-connect/certs

Response:
{
  "keys": [
    {
      "kid": "abc123",
      "kty": "RSA",
      "alg": "RS256",
      "use": "sig",
      "n": "<modulus in base64>",   // Public key modulus
      "e": "<exponent in base64>"   // Public key exponent
    }
  ]
}
```

**JWT Validation Process:**
```
1. Split JWT into header, payload, signature
2. Parse header, extract "kid" (key ID)
3. Fetch JWKS from Keycloak (or use cached keys)
4. Find key with matching "kid"
5. Verify signature using public key:
   - Compute hash of (header + "." + payload)
   - Decrypt signature with public key
   - Compare: hash == decrypted_signature
6. If valid, parse payload and check:
   - exp (expiration) > now
   - iss (issuer) == expected_issuer
   - aud (audience) includes expected_audience
```

**In this architecture:**
- token-exchange-service caches JWKS (refreshed every 15 minutes)
- Every request: validate JWT signature before proceeding
- Invalid/expired tokens → DENY (401 Unauthorized)
- Valid token with wrong audience → EXCHANGE → ALLOW

---

## How Components Communicate

```
┌────────────────────────────────────────────────────────────────────┐
│                    COMMUNICATION DIAGRAM                           │
└────────────────────────────────────────────────────────────────────┘

1. OPERATOR ←→ KEYCLOAK (Admin API)
   Protocol: HTTPS (REST API)
   Purpose: Register clients, get credentials
   Example:
     POST /admin/realms/kagenti/clients
     { "clientId": "tool-ns/echo-tool", ... }

2. WAYPOINT ←→ TOKEN-EXCHANGE-SERVICE (ext_authz)
   Protocol: gRPC (Envoy ext_authz v3)
   Purpose: Authorize requests, get exchanged tokens
   Example:
     CheckRequest { headers: { authorization: "Bearer ..." } }
     CheckResponse { okResponse: { headers: [...] } }

3. TOKEN-EXCHANGE-SERVICE ←→ KEYCLOAK (JWKS + Token Exchange)
   Protocol: HTTPS (REST API)
   Purpose:
     a. Fetch JWKS (public keys for JWT validation)
        GET /realms/kagenti/protocol/openid-connect/certs
     b. Exchange tokens (RFC 8693)
        POST /realms/kagenti/protocol/openid-connect/token
        grant_type=urn:ietf:params:oauth:grant-type:token-exchange

4. APPLICATION POD ←→ ZTUNNEL (mTLS)
   Protocol: mTLS (mutual TLS with SPIFFE identities)
   Purpose: Encrypted transport, identity-based networking
   Example:
     Pod A → ztunnel (encrypt with source=spiffe://ns-a/sa-a)
     → ztunnel → Pod B (decrypt, validate identity)

5. WAYPOINT ←→ APPLICATION POD (HTTP)
   Protocol: HTTP (plain, already encrypted by ztunnel)
   Purpose: Forward authorized requests with correct token
   Example:
     Waypoint receives CheckResponse with new token
     → Forwards HTTP request to pod with Authorization: Bearer <new-token>

6. WEBHOOK ←→ OPERATOR (via annotations)
   Protocol: Kubernetes API (annotation-based contract)
   Purpose: Coordinate secret mounting
   Example:
     Operator sets: kagenti.io/keycloak-client-credentials-secret-name=secret-abc
     Webhook reads annotation → mounts secret to /shared/
```

---

## Complete Request Lifecycle

### Scenario: User calls Agent, Agent calls Tool

```
┌────────────────────────────────────────────────────────────────────┐
│                    PHASE 0: SETUP (HAPPENS ONCE)                   │
└────────────────────────────────────────────────────────────────────┘

1. Platform team deploys agent and tool workloads
   kubectl apply -f agent-deployment.yaml  # label: kagenti.io/type=agent
   kubectl apply -f tool-deployment.yaml   # label: kagenti.io/type=tool

2. kagenti-operator reconciles:
   a. Reads authbridge-config (Keycloak URL, realm)
   b. Reads keycloak-admin-secret (admin credentials)
   c. Registers "agent-ns/demo-agent" in Keycloak
      → Creates Secret: kagenti-keycloak-client-credentials-<hash-agent>
   d. Registers "tool-ns/echo-tool" in Keycloak
      → Creates Secret: kagenti-keycloak-client-credentials-<hash-tool>
   e. Patches pod templates with annotations

3. kagenti-webhook mutates pods:
   a. Injects Envoy/authbridge sidecars (if needed)
   b. Mounts client credentials Secrets to /shared/
      - /shared/client-id.txt
      - /shared/client-secret.txt

4. Platform team creates AuthorizationPolicy in tool-ns:
   kubectl apply -f authz-policy.yaml

5. Istio waypoint deployed in tool-ns:
   istioctl waypoint apply --namespace=tool-ns

┌────────────────────────────────────────────────────────────────────┐
│                  PHASE 1: USER AUTHENTICATES                       │
└────────────────────────────────────────────────────────────────────┘

User (Alice) → Keycloak:

POST /realms/kagenti/protocol/openid-connect/token
{
  grant_type: "password",
  client_id: "agent-ns/demo-agent",     ← From /shared/client-id.txt
  client_secret: "<secret>",             ← From /shared/client-secret.txt
  username: "alice",
  password: "password123"
}

Keycloak Response:
{
  "access_token": "<JWT>",
  "token_type": "Bearer",
  "expires_in": 300
}

JWT Payload:
{
  "iss": "https://keycloak.example.com/realms/kagenti",
  "sub": "user-alice",
  "azp": "agent-ns/demo-agent",
  "aud": [
    "agent-ns/demo-agent",
    "token-exchange-service"
  ],
  "exp": 1234567890
}

┌────────────────────────────────────────────────────────────────────┐
│                  PHASE 2: USER CALLS AGENT                         │
└────────────────────────────────────────────────────────────────────┘

User → Agent:

GET /query HTTP/1.1
Host: demo-agent.agent-ns.svc.cluster.local
Authorization: Bearer <JWT from Phase 1>

Traffic Flow:
1. ztunnel intercepts (mTLS encryption)
2. → Agent waypoint (if AuthorizationPolicy in agent-ns)
3. → Waypoint calls token-exchange-service via ext_authz:

   gRPC CheckRequest:
   {
     headers: {
       "authorization": "Bearer <JWT>",
       ":authority": "demo-agent.agent-ns.svc.cluster.local"
     }
   }

4. token-exchange-service evaluates:
   a. Validate JWT signature (using cached JWKS)
   b. Check audience: "demo-agent" ∈ ["agent-ns/demo-agent", "token-exchange-service"]
   c. Decision: PASS THROUGH ✅ (audience matches)

   gRPC CheckResponse:
   {
     "status": { "code": 0 },  // OK
     "okResponse": {}           // No token modification
   }

5. Waypoint forwards request to demo-agent pod
6. Agent receives request with original JWT

┌────────────────────────────────────────────────────────────────────┐
│                  PHASE 3: AGENT CALLS TOOL                         │
└────────────────────────────────────────────────────────────────────┘

Agent → Tool:

GET /echo HTTP/1.1
Host: echo-tool.tool-ns.svc.cluster.local
Authorization: Bearer <SAME JWT from Phase 1>

Traffic Flow:
1. ztunnel intercepts (mTLS encryption)
2. → Tool waypoint (destination-side)
3. → Waypoint calls token-exchange-service via ext_authz:

   gRPC CheckRequest:
   {
     headers: {
       "authorization": "Bearer <JWT>",
       ":authority": "echo-tool.tool-ns.svc.cluster.local"
     }
   }

4. token-exchange-service evaluates:
   a. Validate JWT signature ✅
   b. Extract service name from host: "echo-tool"
   c. Check audience: "echo-tool" ∈ ["agent-ns/demo-agent", "token-exchange-service"]
      → NOT FOUND ❌
   d. Check cache: hash(JWT + "echo-tool") → MISS (first call)
   e. Call Keycloak RFC 8693 token exchange:

      POST /realms/kagenti/protocol/openid-connect/token
      {
        grant_type: "urn:ietf:params:oauth:grant-type:token-exchange",
        subject_token: "<JWT>",
        audience: "echo-tool",
        client_id: "token-exchange-service",
        client_secret: "<service-secret>"
      }

   f. Keycloak validates:
      - token-exchange-service is authenticated ✅
      - subject_token is valid and not expired ✅
      - "echo-tool" has standard.token.exchange.enabled=true ✅ (set by operator)
      - Exchange is permitted ✅

   g. Keycloak issues new token:
      {
        "iss": "https://keycloak.example.com/realms/kagenti",
        "sub": "user-alice",           ← SAME user (preserved)
        "azp": "token-exchange-service",
        "aud": ["echo-tool"],           ← NEW audience
        "exp": 1234567890
      }

   h. Cache exchanged token (TTL = exp - 30 seconds)
   i. Return to waypoint:

      gRPC CheckResponse:
      {
        "status": { "code": 0 },
        "okResponse": {
          "headers": [
            {
              "key": "authorization",
              "value": "Bearer <EXCHANGED_JWT>"
            }
          ]
        }
      }

5. Waypoint modifies request:
   - Original: Authorization: Bearer <JWT with aud=agent>
   - Modified: Authorization: Bearer <EXCHANGED_JWT with aud=echo-tool>

6. Waypoint forwards modified request to echo-tool pod

7. echo-tool receives request with EXCHANGED_JWT:
   - Can validate: aud includes "echo-tool" ✅
   - Can extract: sub = "user-alice" (knows original user)

┌────────────────────────────────────────────────────────────────────┐
│                  PHASE 4: SUBSEQUENT CALLS (CACHED)                │
└────────────────────────────────────────────────────────────────────┘

Agent calls Tool again (same user, same token):

1-3. Same as Phase 3 (traffic → waypoint → ext_authz)

4. token-exchange-service evaluates:
   a. Validate JWT signature ✅
   b. Check audience: "echo-tool" ∈ aud? → NO
   c. Check cache: hash(JWT + "echo-tool") → HIT ✅
   d. Return cached exchanged token (no Keycloak call)

Latency comparison:
   First call:  ~100ms (Keycloak exchange)
   Second call: <1ms   (cache hit)
   Cache hit rate: >95% in steady state
```

---

## Installation and Deployment

### Prerequisites

```bash
# 1. Kubernetes cluster (Kind for local, ROSA/OpenShift for production)
kind create cluster --name authbridge-test

# 2. Install Istio with ambient profile
istioctl install --set profile=ambient -y

# 3. Deploy Keycloak
helm install keycloak bitnami/keycloak \
  --set auth.adminUser=admin \
  --set auth.adminPassword=admin123 \
  --namespace keycloak --create-namespace
```

### Deploy AuthBridge Components

```bash
# 1. Configure Istio extension provider
make config

# 2. Deploy kagenti-operator
kubectl apply -f operator/deploy.yaml

# 3. Deploy token-exchange-service
make deploy-core

# 4. Create Keycloak realm and clients
./deploy/03-keycloak-setup.sh

# 5. Deploy demo agents and tools
make deploy-demo
```

### Per-Namespace Setup

```bash
# For each namespace that needs authorization:

# 1. Create authbridge-config ConfigMap
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: authbridge-config
  namespace: tool-ns
data:
  KEYCLOAK_URL: "http://keycloak-service.keycloak.svc:8080"
  KEYCLOAK_REALM: "kagenti"
  SPIRE_ENABLED: "false"
EOF

# 2. Create keycloak-admin-secret Secret
kubectl create secret generic keycloak-admin-secret \
  --from-literal=KEYCLOAK_ADMIN_USERNAME=admin \
  --from-literal=KEYCLOAK_ADMIN_PASSWORD=admin123 \
  -n tool-ns

# 3. Deploy waypoint proxy
istioctl waypoint apply --namespace=tool-ns

# 4. Create AuthorizationPolicy
kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: tool-waypoint-token-exchange
  namespace: tool-ns
spec:
  action: CUSTOM
  provider:
    name: kagenti-token-exchange
  rules:
  - to:
    - operation:
        notPaths: ["/.well-known/*", "/healthz"]
EOF

# 5. Deploy workloads with label
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo-tool
  namespace: tool-ns
spec:
  template:
    metadata:
      labels:
        kagenti.io/type: tool  # ← Triggers operator registration
    spec:
      containers:
      - name: echo
        image: echo-tool:latest
EOF
```

---

## Benefits and Trade-offs

### Benefits

| Benefit | Description |
|---------|-------------|
| **Zero Application Changes** | Apps don't need to implement auth logic |
| **Centralized Security** | One service handles all authorization |
| **Least-Privilege Tokens** | Each service gets audience-scoped JWT |
| **Automatic Credential Rotation** | Operator manages Keycloak client lifecycle |
| **No Per-Pod Overhead** | Ambient mesh (no sidecars) + shared service |
| **Multi-Tenant Isolation** | Namespace-scoped policies, no cross-contamination |
| **Audit Trail** | All exchanges logged, original user preserved |
| **Performance** | Token caching (>95% hit rate) |
| **GitOps Friendly** | Declarative YAML for all policies |

### Trade-offs

| Trade-off | Impact | Mitigation |
|-----------|--------|------------|
| **Added Latency** | First call: ~100ms (token exchange) | Cache (subsequent calls <1ms) |
| **Keycloak Dependency** | Single point of failure | HA deployment, token cache survives restart |
| **Complexity** | Multiple components (Istio, Keycloak, operator) | Comprehensive docs, automated deployment |
| **Learning Curve** | Team must understand JWT, OAuth, Istio | Training, runbooks, troubleshooting guides |
| **Keycloak Load** | Many exchanges = Keycloak traffic | Token caching, horizontal scaling |

---

## Comparison with Traditional Approaches

### Approach 1: No Authentication

```
Service A ──────────────► Service B
              HTTP

❌ No identity verification
❌ No access control
❌ Insider threats
❌ Token reuse across services
```

### Approach 2: Shared Secret

```
Service A ────────────────► Service B
      Authorization: Bearer <STATIC_SECRET>

❌ Same secret for all callers
❌ No user context
❌ Hard to rotate
❌ Broad access (same token for everything)
```

### Approach 3: Per-Pod Sidecar (Traditional Service Mesh)

```
┌─────────────────────────┐     ┌─────────────────────────┐
│ Service A               │     │ Service B               │
│ ┌─────┐  ┌───────────┐ │     │ ┌───────────┐  ┌─────┐ │
│ │ App │◄─┤ Envoy     │─┼────►┼─┤ Envoy     │─►│ App │ │
│ └─────┘  │ (sidecar) │ │     │ │ (sidecar) │  └─────┘ │
│          └───────────┘ │     │ └───────────┘          │
└─────────────────────────┘     └─────────────────────────┘

✅ mTLS encryption
✅ Identity-based networking
❌ 2x memory overhead (sidecar in every pod)
❌ Complex startup ordering
❌ Resource consumption per pod
```

### Approach 4: AuthBridge Waypoint (This Architecture)

```
┌───────────┐                            ┌───────────┐
│ Service A │                            │ Service B │
│ ┌───────┐ │                            │ ┌───────┐ │
│ │  App  │ │                            │ │  App  │ │
│ └───┬───┘ │                            │ └───▲───┘ │
└─────┼─────┘                            └─────┼─────┘
      │                                        │
      ▼                                        │
 ┌─────────┐         ┌──────────┐      ┌──────────┐
 │ ztunnel │────────►│ Waypoint │─────►│ ztunnel  │
 │ (node)  │  mTLS   │ (ns-b)   │      │ (node)   │
 └─────────┘         └────┬─────┘      └──────────┘
                          │
                          ▼
              ┌───────────────────────┐
              │ token-exchange-service│
              │ (shared, 1 instance)  │
              └───────────────────────┘

✅ mTLS encryption (ztunnel)
✅ Zero per-pod overhead (no sidecars)
✅ Centralized auth logic
✅ Least-privilege tokens
✅ Automatic client registration
✅ Operator-managed credentials
✅ Token caching (high performance)
```

---

## Summary

AuthBridge Waypoint combines **11 key components** to provide a complete zero-trust authentication solution:

1. **Kubernetes**: Base platform
2. **Istio Ambient Mesh**: Traffic management without sidecars
3. **ztunnel**: Node-level mTLS encryption (Layer 4)
4. **Waypoint Proxy**: Namespace-level HTTP authorization (Layer 7)
5. **Istio Extension Provider**: Configures ext_authz integration
6. **Keycloak**: Identity provider (users, clients, tokens, exchange)
7. **token-exchange-service**: Centralized JWT validation and RFC 8693 exchange
8. **kagenti-operator**: Automatic Keycloak client registration
9. **AuthorizationPolicy**: Per-namespace activation of ext_authz
10. **RFC 8693 Token Exchange**: OAuth protocol for token narrowing
11. **JWT/JWKS**: Token format and signature validation

These components work together to provide:
- **Zero application changes** (transparent to apps)
- **Centralized security** (one service, one policy model)
- **Least-privilege tokens** (audience-scoped per service)
- **Automatic lifecycle management** (operator handles registration)
- **High performance** (token caching, no sidecars)
- **Multi-tenant isolation** (namespace-scoped policies)

The architecture scales from development (Kind) to production (ROSA/OpenShift) without changing the fundamental security model.
