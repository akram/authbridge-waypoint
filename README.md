# Zero-Sidecar Agent Access Control via Shared Token Exchange Service

A proof-of-concept that replaces Kagenti's AuthBridge sidecar architecture (5 containers, ~150-200MB, NET_ADMIN) with **zero sidecars** using a shared token-exchange-service for RFC 8693 token exchange. Two modes, same backend:

- **Waypoint mode** (Istio ambient mesh) — ext_authz filter on the waypoint, no pod-level changes
- **HTTP proxy mode** (no mesh required) — `HTTP_PROXY` env var on agent pods, no sidecar, no NET_ADMIN

## Problem Statement

Kagenti's AuthBridge requires 5 containers per agent pod:
1. Envoy sidecar (ext_proc filter)
2. go-processor (token exchange logic)
3. spiffe-helper (SPIFFE identity)
4. iptables init container (traffic redirection, requires NET_ADMIN)
5. client-registration init container

This adds ~150-200MB memory overhead per pod and requires privileged containers. For multi-tenant environments with many agent pods, this doesn't scale.

## Architecture

```
       agent-ns                                    tool-ns
┌─────────────────────┐       ┌───────────────────────────────────────┐
│                     │       │                                       │
│  Agent Pod          │       │  tool-waypoint (L7)                   │
│  (1 container)      │──────>│  │                                    │
│                     │       │  ├─ ext_authz                         │
│  agent-waypoint(L7) │       │  │  aud missing destination           │
│  │                  │       │  │  → exchange via RFC 8693            │
│  ├─ ext_authz       │       │  │                                    │
│  │  aud has         │       │  ▼                                    │
│  │  "demo-agent"    │       │  ┌─────────────┐  ┌─────────────┐    │
│  │  → pass through  │       │  │ echo-tool   │  │ time-tool   │    │
│  ▼                  │       │  │ (1 ctr)     │  │ (1 ctr)     │    │
└─────────────────────┘       │  └─────────────┘  └─────────────┘    │
                              │                                       │
                              └───────────────────────────────────────┘
```

**Two waypoints, one shared ext_authz service, zero per-tool config:**

- **agent-waypoint** (agent-ns) — token `aud` includes destination → pass through
- **tool-waypoint** (tool-ns) — token `aud` missing destination → exchange via RFC 8693

Both tools share the same waypoint and policy. Adding a tool requires only a Keycloak client and a Deployment — no new waypoint, policy, or namespace.

The service derives the destination audience from the hostname (convention: K8s service name = first segment of FQDN). No audience maps or direction config needed — the token's `aud` claim is the signal.

**Token flow (same for any tool):**

1. User calls `demo-agent` with a JWT (`aud` includes `demo-agent`)
2. agent-waypoint: ext_authz validates JWT, `aud` includes `demo-agent` → pass through
3. `demo-agent` forwards the request to a tool (`echo-tool` or `time-tool`)
4. tool waypoint: ext_authz validates JWT, `aud` missing tool name → exchange
   - Calls Keycloak RFC 8693 token exchange
   - Replaces `Authorization` header with tool-scoped token
5. Tool receives the exchanged token (`aud=<tool-name>`, `sub` preserved)

Adding a new tool to an existing namespace requires only: 1 Keycloak client + audience mapper, 1 Deployment. No changes to the agent, token-exchange-service, waypoint, policy, or existing tools.

## What This Proves

| Property | AuthBridge (current) | Waypoint PoC |
|----------|---------------------|--------------|
| Containers per agent pod | 5 (envoy, go-processor, spiffe-helper, 2 init) | 1 |
| Memory overhead per pod | ~150-200MB | 0 (shared waypoints) |
| NET_ADMIN / iptables | Required | Not needed |
| HTTP_PROXY env vars | Required | Optional (HTTP proxy mode) or not needed (waypoint mode) |
| Token exchange | Per-pod sidecar | Shared service (ext_authz or HTTP proxy) |
| Access control | Sidecar code | Declarative AuthorizationPolicy CRs |

## Why ext_authz

| | ext_authz | ext_proc |
|---|-----------|----------|
| Protocol | Unary gRPC (request/response) | Bidirectional gRPC stream |
| Complexity | Simple — one CheckRequest, one CheckResponse | Complex — multiple ProcessingRequest/Response per HTTP transaction |
| Header mutation | `OkHttpResponse.headers_to_set` | `HeaderMutation` in response to `request_headers` phase |
| Istio integration | Native via `AuthorizationPolicy CUSTOM` | Requires `EnvoyFilter` (not recommended for ambient) |
| Shared service | Natural — stateless, one call per request | Harder — stream lifetime tied to connection |

JWT validation and token exchange are both handled in ext_authz (not `RequestAuthentication`) because:
- Single point of logic — validation and exchange are tightly coupled
- Meaningful error messages (`{"error": "token expired"}`) vs generic 401
- Requests without an Authorization header are allowed only on bypass paths (`/.well-known/*`, `/healthz`, `/readyz`, `/livez`). All other unauthenticated requests are rejected. Override via `BYPASS_INBOUND_PATHS` env var (comma-separated, same pattern as AuthBridge).
- No two-phase problem — the waypoint doesn't need to skip validation of the exchanged token

## Istio Extension Provider

An **extension provider** in Istio is a mechanism to plug external services into Envoy's request processing pipeline. Think of it as a hook that lets you run custom logic on every request.

### Configuration

The `kagenti-token-exchange` extension provider is configured in the Istio mesh (`make config` adds this):

```yaml
extensionProviders:
- name: kagenti-token-exchange
  envoyExtAuthzGrpc:
    service: token-exchange-service.kagenti-system.svc.cluster.local
    port: 9090
```

This registration makes the provider **available** to any waypoint or gateway in the cluster, but doesn't activate it yet.

### Activation via AuthorizationPolicy

The provider is activated by referencing it in an `AuthorizationPolicy`:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: tool-waypoint-token-exchange
  namespace: tool-ns
spec:
  action: CUSTOM
  provider:
    name: kagenti-token-exchange  # ← References the extension provider
  rules:
  - to:
    - operation:
        notPaths: ["/.well-known/*", "/healthz", "/readyz"]
```

### Request Flow

When a request hits a waypoint with this policy:

```
Client Request
    │
    ▼
Waypoint (Envoy) ──────────────┐
    │                          │
    │                          ▼
    │                    ext_authz gRPC call
    │                    token-exchange-service:9090
    │                          │
    │                          ├─ 1. Validate JWT
    │                          ├─ 2. Check if aud includes destination
    │                          ├─ 3. If not, exchange via Keycloak
    │                          └─ 4. Return OK + replacement header
    │                          │
    ▼                          ▼
Modified Request ◄─────── CheckResponse
(Authorization: Bearer <tool-token>)
    │
    ▼
Tool Service
```

### Why External Authorization?

Comparison with Istio's built-in JWT validation:

| Feature | RequestAuthentication | ext_authz (our approach) |
|---------|----------------------|-------------------------|
| JWT validation | ✅ Yes | ✅ Yes |
| Token exchange | ❌ No | ✅ Yes |
| Header mutation | ❌ No | ✅ Can replace headers |
| Custom error messages | ❌ Generic 401 | ✅ `{"error": "token expired"}` |
| Bypass paths | Complex (multiple policies) | ✅ Simple (`notPaths` rule) |
| Shared logic | Per-namespace | ✅ One service for entire cluster |

### Multi-Waypoint Architecture

One extension provider service handles all waypoints:

```
┌─────────────────────────────────────────────────────────┐
│      token-exchange-service (kagenti-system)            │
│                                                         │
│  gRPC: envoy.service.auth.v3.Authorization              │
│  - Validates JWT                                        │
│  - Exchanges tokens via Keycloak                        │
│  - Caches results                                       │
└──────────────┬──────────────────────────────────────────┘
               │
   ┌───────────┴──────────┬─────────────────┬────────────
   ▼                      ▼                 ▼
agent-waypoint       tool-waypoint    egress-gateway
(agent-ns)           (tool-ns)        (istio-system)
   │                      │                 │
   │ aud includes         │ aud missing     │ external tools
   │ destination          │ destination     │
   │ → pass through       │ → exchange      │ → exchange
```

Each waypoint references the same `kagenti-token-exchange` provider, but the service makes different decisions based on the request context (specifically, whether the token's `aud` claim includes the destination service name).

### What `make config` Does

Running `make config` is a **one-time setup** that registers the extension provider with Istio:

1. **Patches the Istio ConfigMap** (`istio` in `istio-system` namespace)
2. **Adds the extensionProviders entry**:
   ```yaml
   extensionProviders:
   - name: kagenti-token-exchange
     envoyExtAuthzGrpc:
       service: token-exchange-service.kagenti-system.svc.cluster.local
       port: 9090
   ```
3. **Makes the provider available** cluster-wide (but doesn't activate it)
4. **Idempotent**: Safe to run multiple times, skips if already configured

After running `make config`, the provider is registered but inactive. It only becomes active when an `AuthorizationPolicy` references it by name. This two-phase approach (registration + activation) allows you to:
- Register the provider once globally
- Activate it selectively in specific namespaces via policies
- Use the same provider across multiple waypoints without duplication

**Note**: After `make config`, istiod may need a restart to pick up the change, or wait a few minutes for automatic detection:
```bash
kubectl rollout restart deployment/istiod -n istio-system
```

## Token Exchange Service Deep Dive

The **token-exchange-service** (`cmd/token-exchange-service/`) is the core of this architecture. It's a single Go service deployed in `kagenti-system` namespace that handles all JWT validation and token exchange for the entire cluster.

### Dual Interface Design

The service provides two interfaces with identical authorization logic:

```
┌────────────────────────────────────────────────────────────┐
│            token-exchange-service (kagenti-system)         │
│                                                            │
│  ┌─────────────────┐              ┌──────────────────┐    │
│  │  gRPC :9090     │              │  HTTP Proxy :8080│    │
│  │  (ext_authz)    │              │  (HTTP_PROXY)    │    │
│  └────────┬────────┘              └────────┬─────────┘    │
│           │                                │              │
│           └──────────┬─────────────────────┘              │
│                      ▼                                    │
│           ┌──────────────────────┐                        │
│           │  Shared Auth Logic   │                        │
│           │  - Validate JWT      │                        │
│           │  - Check aud         │                        │
│           │  - Exchange if needed│                        │
│           └──────────────────────┘                        │
└────────────────────────────────────────────────────────────┘
```

**1. gRPC ext_authz (Port 9090)** - For Istio waypoints
- Protocol: `envoy.service.auth.v3.Authorization`
- Called by Envoy's ext_authz filter
- Returns: `CheckResponse` with `OkHttpResponse.headers_to_set`
- Used in: Waypoint mode (ambient mesh)

**2. HTTP Forward Proxy (Port 8080)** - For standard HTTP clients
- Protocol: HTTP CONNECT proxy
- Set via `HTTP_PROXY` environment variable on workloads
- Returns: Proxied response with modified `Authorization` header
- Used in: Non-mesh mode (any namespace)

### Authorization Decision Logic

For every request, the service follows this decision tree:

```
1. Extract Authorization header
   ├─ Missing + bypass path (/.well-known/*, /healthz)
   │  └─ ALLOW (no auth required)
   └─ Missing + protected path
      └─ DENY (401 "no Authorization header")

2. Validate JWT
   ├─ Parse and verify signature (using cached JWKS)
   ├─ Check issuer (must match ISSUER_URL)
   └─ Check expiration
      ├─ Invalid → DENY (401 with specific error)
      └─ Valid → continue

3. Check audience (aud claim)
   ├─ Extract destination from Host header
   │  Example: "echo-tool.tool-ns.svc.cluster.local" → "echo-tool"
   └─ Check if token.aud includes destination

4. Make decision
   ├─ aud includes destination
   │  └─ ALLOW (pass through original token)
   └─ aud missing destination
      └─ EXCHANGE via Keycloak RFC 8693
         ├─ Check cache (subject_token_hash, audience)
         │  ├─ HIT → return cached token
         │  └─ MISS → call Keycloak
         ├─ POST /realms/kagenti/protocol/openid-connect/token
         │  grant_type=urn:ietf:params:oauth:grant-type:token-exchange
         │  subject_token=<original>
         │  audience=<destination>
         ├─ Cache result (TTL = expires_in - 30s)
         └─ ALLOW with replacement token (aud=destination)
```

### Why This Design Works

**Convention over Configuration**:
- Service name = first segment of FQDN = Keycloak client ID
- Example: `echo-tool.tool-ns.svc` → audience `echo-tool`
- No mapping files, no per-tool configuration

**Smart Caching**:
- **JWKS cache**: Keycloak public keys (15min refresh)
  - Avoids calling `/certs` on every request
  - Typical: 10-20 keys × 2KB = ~40KB
- **Token cache**: Exchanged tokens (TTL = expires_in - 30s)
  - Key: SHA-256(subject_token, audience)
  - Avoids repeated exchanges for same user→tool
  - Latency: cached=<1ms, uncached=50-100ms

**Bypass Paths**:
- Health checks: `/healthz`, `/readyz`, `/livez`
- Public metadata: `/.well-known/*`
- Configurable via `BYPASS_INBOUND_PATHS` env var
- Only applies when **no Authorization header** present

### Configuration

All configuration via environment variables:

| Variable | Default | Purpose |
|----------|---------|---------|
| `KEYCLOAK_URL` | `http://keycloak-service.keycloak.svc:8080` | Internal URL for JWKS and token exchange API |
| `ISSUER_URL` | (same as KEYCLOAK_URL) | External issuer for JWT validation |
| `REALM` | `kagenti` | Keycloak realm |
| `CLIENT_ID` | `token-exchange-service` | Service's Keycloak client ID |
| `CLIENT_SECRET` | **(required)** | Service's Keycloak client secret |
| `LISTEN_ADDR` | `:9090` | gRPC ext_authz listen address |
| `PROXY_LISTEN_ADDR` | (disabled) | HTTP proxy listen address |
| `BYPASS_INBOUND_PATHS` | `/.well-known/*,/healthz,/readyz,/livez` | Comma-separated bypass patterns |

**Critical: ISSUER_URL**

The `ISSUER_URL` must **exactly match** the `iss` claim in tokens:
- Tokens from port-forward: `http://localhost:18080/realms/kagenti`
- Tokens from ROSA route: `https://keycloak-keycloak.apps.rosa.../realms/kagenti`

Mismatch causes: `"invalid issuer: got X, want Y"` errors.

On OpenShift, `make up` automatically sets:
```bash
kubectl set env deployment/token-exchange-service -n kagenti-system \
  ISSUER_URL=https://keycloak-keycloak.apps.rosa.akram.dxp0.p3.openshiftapps.com
```

### Error Messages

The service returns **specific error messages** for debugging:

| Error | Code | When |
|-------|------|------|
| `no Authorization header` | 401 | Missing header on protected path |
| `token is malformed: ...` | 401 | Invalid JWT structure |
| `invalid token: ...` | 401 | Signature verification failed |
| `token expired` | 401 | JWT `exp` in the past |
| `invalid issuer: got X, want Y` | 401 | Issuer mismatch |
| `token exchange failed: ...` | 403 | Keycloak rejected exchange |

These errors propagate through demo-agent:
```json
{
  "tool_status": 401,
  "tool_response_raw": {
    "error": "invalid token: token is expired"
  }
}
```

### Performance Characteristics

| Scenario | Latency | Notes |
|----------|---------|-------|
| Token cache HIT | <1ms | In-memory lookup |
| Token cache MISS | 50-100ms | Keycloak exchange call |
| JWKS cache MISS | +10-20ms | Fetch public keys |
| Cold start | 100-150ms | Both caches empty |

**Throughput**: Handles thousands of concurrent requests (limited by Keycloak, not the service).

### Full Documentation

See [cmd/token-exchange-service/README.md](cmd/token-exchange-service/README.md) for:
- Complete architecture diagrams
- Detailed caching strategy
- Token exchange flow walkthrough
- Troubleshooting guide
- Security considerations
- Future enhancements

## Waypoint Placement

Istio waypoints are **strictly destination-side** — they intercept traffic going TO services in their namespace, never outbound FROM them. This was validated during the PoC: a workload-level waypoint (`waypoint-for: workload` or `all`) in agent-ns does not see outbound calls to tools in other namespaces.

| Waypoint | Namespace | waypoint-for | Responsibility |
|----------|-----------|-------------|----------------|
| agent-waypoint | agent-ns | all | `aud` includes destination → pass through |
| tool-waypoint | tool-ns | service | `aud` missing destination → exchange (covers all tools in tool-ns) |

**Istio policy chain:**

```
Inbound: User → agent-waypoint → Agent Pod
                    │
                    └─ ext_authz: validate JWT, check aud
                       aud includes "demo-agent" → pass through

Outbound: Agent Pod → ztunnel → tool-waypoint → Tool Pod
                                     │
                                     └─ ext_authz: validate JWT, check aud
                                        aud missing "echo-tool" → exchange via RFC 8693
```

## External Tools via Egress Gateway

For tools outside the cluster, the same ext_authz service works via the Istio **egress gateway**:

```
Agent Pod → ztunnel → egress gateway → external tool (api.github.com)
                         │
                         └─ ext_authz: validate + exchange
```

A `ServiceEntry` defines the external tool, and an `AuthorizationPolicy CUSTOM` on the egress gateway triggers the same `token-exchange-service`. For external hostnames where the convention (first FQDN segment) doesn't map to a Keycloak client ID, an override mechanism would be needed.

One token-exchange-service handles all in-cluster destinations:

| Destination | Interception point |
|---|---|
| In-cluster tool (different namespace) | tool-ns waypoint |
| In-cluster tool (same namespace) | namespace waypoint |
| External tool | egress gateway |

## Keycloak: Setup and Runtime

Keycloak 26 ships with **Standard Token Exchange V2** built-in — no server-level feature flags needed. This was validated by running E2E tests with Keycloak in production mode with zero preview features.

### How Keycloak is used at runtime

The token-exchange-service calls Keycloak twice during its lifecycle:

**1. JWKS fetch** (background, every 15 minutes):
```
GET /realms/kagenti/protocol/openid-connect/certs
→ Returns the realm's RSA public keys for JWT signature verification
```
The service caches these keys and uses them to validate every incoming JWT without calling Keycloak per-request.

**2. Token exchange** (per-request, when `aud` is missing the destination):
```
POST /realms/kagenti/protocol/openid-connect/token

  grant_type         = urn:ietf:params:oauth:grant-type:token-exchange
  subject_token      = <the agent's JWT>
  subject_token_type = urn:ietf:params:oauth:token-type:access_token
  audience           = echo-tool          ← derived from destination hostname
  client_id          = token-exchange-service
  client_secret      = exchange-secret

→ Returns: { access_token: <tool-scoped JWT>, expires_in: 300 }
```

Exchanged tokens are cached keyed by `(subject_token_hash, audience)` with TTL = `expires_in - 30s`, so repeated calls to the same tool skip Keycloak entirely.

### What Keycloak checks during exchange

When the token exchange request arrives, Keycloak validates three things:

```
1. Is token-exchange-service allowed to call the exchange endpoint?
   → Check: standard.token.exchange.enabled = "true" on token-exchange-service
   → Without this: "Client not allowed to exchange"

2. Is the subject_token valid?
   → Check: signature, issuer, expiry (same as any JWT validation)

3. Is token-exchange-service in the subject_token's audience?
   → Check: subject_token.aud includes "token-exchange-service"
   → Without this: "Client not allowed to exchange: not in subject token audience"
   → This is why demo-agent needs the token-exchange-service audience mapper
```

The exchanged token has:
- `aud`: `echo-tool` (the target tool's client ID)
- `azp`: `token-exchange-service` (the client that performed the exchange)
- `sub`: same as the original agent token's subject (preserved through exchange)

### Setup (deploy/03-keycloak-setup.sh)

The setup script configures Keycloak via the admin REST API. Here's what it creates and why:

**Step 1 — Realm**: Uses the existing `kagenti` realm (shared with the kagenti platform). Creates it if not present.

**Step 2 — Four clients:**

| Client | Role | Secret |
|--------|------|--------|
| `demo-agent` | The agent. Users obtain tokens from this client via `client_credentials` grant. | `agent-secret` |
| `echo-tool` | A tool. Represents the target audience for exchanged tokens. | `tool-secret` |
| `time-tool` | A tool. Second tool for multi-tool demo. | `time-tool-secret` |
| `token-exchange-service` | The shared ext_authz service. Authenticates to Keycloak to perform exchanges on behalf of agents. | `exchange-secret` |

**Step 3 — Enable standard token exchange** (`standard.token.exchange.enabled = "true"`):

Set on `token-exchange-service` only. This is a per-client attribute in Keycloak 26 that allows the client to call the token exchange endpoint. Without it, Keycloak returns `"Client not allowed to exchange"`.

Only the **requesting client** needs this attribute. The target audience client (`echo-tool`) and the token owner (`demo-agent`) do not.

**Step 4 — Audience mappers** (control what goes into the `aud` claim of issued tokens):

| # | Mapper on client | Adds to `aud` | Why |
|---|-----------------|---------------|-----|
| 1 | `demo-agent` | `demo-agent` | Agent tokens include the agent's own name. This is how the ext_authz knows to pass through on inbound: `aud` includes the destination (`demo-agent`). |
| 2 | `demo-agent` | `token-exchange-service` | **Required by Keycloak.** When `token-exchange-service` presents the agent's token as `subject_token`, Keycloak checks that the requesting client (`token-exchange-service`) is in the subject token's `aud`. Without this mapper, the exchange fails. |
| 3 | `token-exchange-service` | `echo-tool` | When Keycloak issues the exchanged token, this mapper ensures `echo-tool` appears in the `aud` claim. |
| 4 | `token-exchange-service` | `time-tool` | Same as above for the second tool. Each new tool needs one audience mapper on `token-exchange-service`. |
| 5 | `kagenti` (platform) | `token-exchange-service` | Allows the kagenti platform (UI/backend) tokens to be exchanged by the ext_authz. Same role as mapper 2, but for the platform client. |

**Step 5 — Verify**: The script obtains an agent token and performs a test exchange to confirm everything is wired correctly.

### Token lifecycle end-to-end

```
1. User authenticates:
   POST /token  client_id=demo-agent  client_secret=agent-secret
   grant_type=client_credentials

   → Keycloak returns:
     { aud: [demo-agent, token-exchange-service, account], azp: demo-agent, sub: <user-id> }
              ↑ mapper 1   ↑ mapper 2

2. User calls demo-agent with this token.

3. agent-waypoint intercepts (inbound):
   ext_authz: aud includes "demo-agent"? → YES → pass through

4. demo-agent forwards request to echo-tool.

5. tool-waypoint intercepts (outbound):
   ext_authz: aud includes "echo-tool"? → NO → exchange

6. ext_authz calls Keycloak:
   POST /token  grant_type=token-exchange
     subject_token = <agent token from step 1>
     audience = echo-tool
     client_id = token-exchange-service
     client_secret = exchange-secret

   Keycloak checks:
     ✓ token-exchange-service has standard.token.exchange.enabled
     ✓ subject_token is valid (signature, issuer, expiry)
     ✓ subject_token.aud includes token-exchange-service (mapper 2)

   → Keycloak returns:
     { aud: echo-tool, azp: token-exchange-service, sub: <same user-id> }
              ↑ mapper 3

7. ext_authz replaces Authorization header with the exchanged token.

8. echo-tool receives the request with aud=echo-tool.
```

### Issuer URL split

The token `iss` claim uses Keycloak's external hostname (e.g., `http://keycloak.localtest.me:8080`), which may differ from the in-cluster service URL (e.g., `http://keycloak-service.keycloak.svc:8080`). The token-exchange-service uses:
- `KEYCLOAK_URL` — internal service URL for JWKS fetch and token exchange API calls
- `ISSUER_URL` — external URL for JWT issuer validation (must match the `iss` claim in tokens)

## Prerequisites

A **kagenti cluster** already deployed locally, providing:

- **Kind cluster** named `kagenti` (override with `CLUSTER_NAME=<name>`)
- **Istio ambient mesh** with the `kagenti-token-exchange` ext_authz provider configured
- **Keycloak 26+** running in the `keycloak` namespace (service: `keycloak-service`)
- **`kagenti-system` namespace** for shared infrastructure

See the [kagenti repository](https://github.com/kagenti/kagenti) for cluster setup instructions.

## Quick Start

```bash
make config # configure Istio mesh with ext_authz provider (one-time setup)
make up     # build + configure Keycloak + deploy
make test   # run E2E tests
make down   # remove K8s resources + Keycloak clients (realm is shared)
```

**First time setup**: Run `make config` to add the `kagenti-token-exchange` ext_authz provider to your Istio mesh configuration. This is a one-time operation that patches the `istio` ConfigMap in `istio-system`.

## Platform Detection

The Makefile automatically detects whether you're running on **OpenShift** or **Kind** and configures itself accordingly.

### Auto-Detection

Platform detection is based on the presence of `route.openshift.io` API resources:

| Platform | Detection | Registry | Keycloak Access |
|----------|-----------|----------|-----------------|
| **OpenShift** | `route.openshift.io` API exists | `image-registry.openshift-image-registry.svc:5000/kagenti-images` | Via ROSA route (HTTPS) |
| **Kind** | No OpenShift APIs | `localhost:5000` | Via port-forward (HTTP) |

### Check Your Platform

```bash
make platform
```

Example output (OpenShift):
```
Platform: openshift
Registry: image-registry.openshift-image-registry.svc:5000/kagenti-images
KC_URL: https://keycloak-keycloak.apps.rosa.akram.dxp0.p3.openshiftapps.com
Services: demo-agent echo-tool time-tool token-exchange-service
```

### Platform-Specific Behavior

#### OpenShift (ROSA)

On OpenShift, `make up` uses **S2I (Source-to-Image) builds**:

1. Triggers OpenShift BuildConfigs in the `kagenti-images` namespace
2. Uses `oc start-build` for each service
3. Images pushed to internal OpenShift registry
4. Updates deployments to use OpenShift registry images
5. Configures Keycloak via the ROSA route (no port-forwarding)

**Prerequisites:**
```bash
# 0. Configure Istio mesh (one-time)
make config

# 1. Create build namespace
kubectl create namespace kagenti-images

# 2. Deploy BuildConfigs
kubectl apply -f deploy/openshift/golang-s2i-buildconfigs.yaml

# 3. Set up image pull permissions
kubectl apply -f deploy/openshift/image-puller-bindings.yaml

# 4. Verify Keycloak route exists
kubectl get route keycloak -n keycloak
```

#### Kind (Local)

On Kind, `make up` uses **Docker builds**:

1. Builds Go binaries locally
2. Creates Docker images with local Docker daemon
3. Loads images into Kind cluster
4. Port-forwards to Keycloak for setup
5. Deploys with `localhost:5000` image references

**Prerequisites:**
```bash
# 0. Configure Istio mesh (one-time)
make config

# 1. Kind cluster must be named 'kagenti' (or override CLUSTER_NAME)
kind get clusters | grep kagenti
```

### Environment Variables

Override auto-detected settings:

| Variable | Default (OpenShift) | Default (Kind) | Description |
|----------|---------------------|----------------|-------------|
| `OPENSHIFT_IMAGE_PROJECT` | `kagenti-images` | N/A | Namespace for S2I builds |
| `REGISTRY` | (auto) | `localhost:5000` | Container registry |
| `KC_URL` | (from route) | `http://localhost:18080` | Keycloak URL |
| `CLUSTER_NAME` | N/A | `kagenti` | Kind cluster name |
| `TAG` | `latest` | `latest` | Image tag |

**Examples:**

```bash
# Use custom build namespace on OpenShift
make up OPENSHIFT_IMAGE_PROJECT=my-builds

# Force specific registry
make up REGISTRY=my-registry.example.com/project

# Use custom Keycloak URL
make test KC_URL=https://my-keycloak.example.com
```

### Testing on OpenShift

Tests automatically use:
- Keycloak ROSA route (HTTPS, no port-forward)
- UBI-based curl image (avoids Docker Hub rate limits)
- OpenShift registry for test workloads

```bash
make test
# Equivalent to:
# KC_URL=https://keycloak-... CURL_TEST_IMAGE=registry.access.redhat.com/ubi9/ubi-minimal:latest bash deploy/09-test.sh
```

## Components

| Component | Path | Description |
|-----------|------|-------------|
| `demo-agent` | `cmd/demo-agent/` | Receives a user token, forwards it to echo-tool or time-tool |
| `echo-tool` | `cmd/echo-tool/` | Echoes request headers as JSON — verifies the exchanged token |
| `time-tool` | `cmd/time-tool/` | Returns current time + JWT claims — second tool for multi-tool demo |
| `token-exchange-service` | [`cmd/token-exchange-service/`](cmd/token-exchange-service/) | **Core service**: JWT validation + RFC 8693 token exchange. Dual interface: gRPC ext_authz (waypoint) + HTTP forward proxy (HTTP_PROXY). [Full documentation →](cmd/token-exchange-service/README.md) |

## Demo Scripts

| Script | Description |
|--------|-------------|
| `deploy/10-add-tool-demo.sh` | Interactive demo: add a new tool (weather-tool) with zero infra changes |
| `deploy/11-weather-agent-demo.sh` | Deploy real kagenti weather agent + tool with waypoint security |

## End-to-End Tests

| Test | Input | Expected |
|------|-------|----------|
| **Invalid token rejected** | Invalid token → agent-waypoint | ext_authz rejects (HTTP 401) before reaching agent |
| **Valid token → echo-tool** | Valid token → demo-agent → tool-waypoint | Token exchanged; echo-tool receives `aud=echo-tool`, `sub` preserved |
| **Valid token → time-tool** | Valid token → demo-agent → tool-waypoint | Token exchanged; time-tool receives `aud=time-tool`, `sub` preserved |
| **HTTP proxy mode** | Valid token → demo-agent → echo-tool (no mesh, via `HTTP_PROXY`) | Token exchanged via HTTP proxy; same result as waypoint mode |

```bash
make test
```

## Known Constraints

1. **Waypoints are destination-side only** — Istio waypoints intercept traffic going TO services, not FROM. Outbound token exchange requires a waypoint in the tool namespace.
2. **CUSTOM action does not support `from.source.namespaces`** — Namespace filtering must use a separate ALLOW policy.
3. **One waypoint per tool namespace** — each tool namespace needs its own waypoint, but all tools within the namespace share it. Managed declaratively via namespace labels and AuthorizationPolicy CRs.
4. **No mTLS to Keycloak** — the token-exchange-service calls Keycloak over plain HTTP. Production should use TLS.
5. **In-memory cache** — token cache doesn't survive pod restarts. Production could use Redis.
6. **Convention: Keycloak client ID must match K8s service name** — the audience is derived from the hostname. If they differ, an override mechanism would be needed (not yet implemented).
7. **Convention doesn't work for external hostnames** — `api.github.com` → first segment is `api`, not a Keycloak client ID. External tools would need an explicit mapping.
8. **Issuer URL must be configured separately** — when Keycloak's external hostname differs from the internal service name.
