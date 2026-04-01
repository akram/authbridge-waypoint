# Documentation

This directory contains detailed explanations of key architectural concepts and common questions about the authbridge-waypoint design.

## Design Overview

The authbridge-waypoint architecture replaces per-pod sidecars with a **shared token-exchange-service** that provides JWT validation and RFC 8693 token exchange for the entire cluster.

### Core Principles

1. **Shared Service Architecture**
   - One `token-exchange-service` in `kagenti-system` namespace
   - Serves all waypoints and HTTP proxy clients cluster-wide
   - Zero per-pod overhead (no sidecars)

2. **Dual Interface**
   - **gRPC ext_authz** for Istio waypoints (ambient mesh mode)
   - **HTTP forward proxy** for workloads via `HTTP_PROXY` (no mesh required)

3. **Audience-Based Routing**
   - If `token.aud` includes destination → pass through
   - If `token.aud` missing destination → exchange via Keycloak
   - Convention: service name = Keycloak client ID

4. **Namespace Isolation**
   - Extension provider: registered cluster-wide, activated per-namespace
   - AuthorizationPolicy: namespace-scoped, no cross-contamination
   - Each namespace controls its own security policies

## Detailed Documentation

### Architecture and Configuration

- **[Extension Provider Scope and Auto-Enablement](extension-provider-scope.md)**
  - Does the extension provider impact other projects?
  - How to auto-enable for labeled namespaces
  - Registration vs activation model
  - Multi-tenant cluster considerations
  - Options for automated policy deployment

- **[Cross-Namespace Communication](cross-namespace-communication.md)**
  - How authorization works across namespace boundaries
  - Agent-to-tool communication (different namespaces)
  - Agent-to-agent communication patterns
  - Tool chaining and token propagation
  - Multi-namespace deployment strategies
  - Token audience strategies (broad vs dynamic exchange)

- **[Operator Client Registration Integration](operator-client-registration-integration.md)**
  - How kagenti-operator and token-exchange-service work together
  - Two-phase security model (client lifecycle + runtime exchange)
  - Keycloak client registration and credential provisioning
  - RFC 8693 token exchange flow
  - Complete E2E example with operator-managed clients
  - Configuration requirements and troubleshooting

### Service Documentation

- **[Token Exchange Service](../cmd/token-exchange-service/README.md)**
  - Complete service architecture
  - Configuration reference
  - Caching strategy
  - Performance characteristics
  - Troubleshooting guide

## Quick Reference

### Key Components

```
┌─────────────────────────────────────────────────────────────┐
│                   Istio Mesh (cluster-wide)                 │
│                                                             │
│  extensionProviders:                                        │
│  - name: kagenti-token-exchange  ← Registered globally     │
│    envoyExtAuthzGrpc:                                       │
│      service: token-exchange-service.kagenti-system...      │
└─────────────────────────────────────────────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
        ▼                     ▼                     ▼
┌───────────────┐    ┌───────────────┐    ┌───────────────┐
│  Namespace A  │    │  Namespace B  │    │  Namespace C  │
│               │    │               │    │               │
│ AuthPolicy    │    │ AuthPolicy    │    │ (no policy)   │
│ (references   │    │ (references   │    │               │
│  provider)    │    │  provider)    │    │ → unaffected  │
│               │    │               │    │               │
│ → protected   │    │ → protected   │    │               │
└───────────────┘    └───────────────┘    └───────────────┘
```

### Request Flow

```
User → Agent (any namespace)
         │
         ├─→ Tool (same namespace)
         │   └─ Namespace waypoint → ext_authz → exchange if needed
         │
         ├─→ Tool (different namespace)
         │   └─ Destination waypoint → ext_authz → exchange if needed
         │
         └─→ External service
             └─ Egress gateway → ext_authz → exchange if needed

All ext_authz calls → token-exchange-service.kagenti-system
```

### Token Lifecycle

```
1. User authenticates → Keycloak
   Token: { aud: ["agent", "token-exchange-service"] }

2. User calls Agent
   Agent waypoint: aud includes "agent" → PASS THROUGH ✅

3. Agent calls Tool
   Tool waypoint: aud missing "tool" → EXCHANGE 🔄

4. Tool receives token
   Token: { aud: "tool", sub: <original-user> }
```

## Common Use Cases

### 1. Adding a New Tool

**No infrastructure changes needed:**

```bash
# 1. Register in Keycloak
./deploy/10-add-tool-demo.sh

# 2. Deploy the tool
kubectl apply -f my-tool-deployment.yaml

# Done - waypoint automatically handles token exchange
```

### 2. Enabling Auth for a Namespace

```bash
# Option 1: Manual
kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: kagenti-token-exchange
  namespace: my-namespace
spec:
  action: CUSTOM
  provider:
    name: kagenti-token-exchange
  rules:
  - to:
    - operation:
        notPaths: ["/.well-known/*", "/healthz"]
EOF

# Option 2: Label-based (requires automation)
kubectl label namespace my-namespace kagenti.io/auth=enabled
```

### 3. Cross-Namespace Communication

```yaml
# Agent in namespace-a calls tool in namespace-b
# Token: { aud: ["agent-a", "token-exchange-service"] }
#
# Traffic flow:
# agent-a → tool-b.namespace-b
#           ↓
#       namespace-b waypoint (ext_authz)
#           ↓
#       token-exchange-service
#           ↓ (exchange for aud=tool-b)
#       tool-b receives: { aud: "tool-b", sub: <user> }
```

## Security Model

### Threat Model

**Protected against:**
- ✅ Invalid/expired tokens (JWT validation)
- ✅ Token reuse across services (audience scoping)
- ✅ Unauthorized service access (ext_authz gate)
- ✅ Token forgery (signature verification)

**Assumptions:**
- Trust in Keycloak (single point of token issuance)
- Trust in token-exchange-service (performs validation)
- mTLS between services (Istio ambient mesh)

### Defense in Depth

```
Layer 1: Network (Istio mTLS)
Layer 2: Waypoint (ext_authz gate)
Layer 3: Token validation (signature, issuer, expiry)
Layer 4: Audience check (service-specific scoping)
Layer 5: Token exchange (least-privilege tokens)
```

## Performance

### Latency Impact

| Scenario | Added Latency | Notes |
|----------|---------------|-------|
| Token cache HIT | <1ms | In-memory lookup |
| Token cache MISS | 50-100ms | Keycloak exchange (first call only) |
| JWKS cache MISS | +10-20ms | Fetch public keys (every 15min) |

### Scalability

- **Horizontal**: Deploy multiple token-exchange-service replicas
- **Vertical**: Service handles thousands of concurrent requests
- **Bottleneck**: Keycloak (mitigated by token caching)

### Cache Efficiency

```
Typical cache hit rate: >95% (steady state)
- Same user calling same tool repeatedly → 100% hit
- Different users calling same tool → exchange per user (cached)
- Same user calling different tools → exchange per tool (cached)
```

## Troubleshooting

### Common Issues

**"invalid issuer" errors**
→ See [Extension Provider Scope](extension-provider-scope.md#troubleshooting)

**Cross-namespace calls failing**
→ See [Cross-Namespace Communication](cross-namespace-communication.md#troubleshooting)

**High latency**
→ Check [Token Exchange Service](../cmd/token-exchange-service/README.md#troubleshooting)

### Debug Commands

```bash
# Check extension provider registration
kubectl get cm istio -n istio-system -o yaml | grep -A 5 kagenti-token-exchange

# Check policy in namespace
kubectl get authorizationpolicy -n <namespace>

# Check token-exchange-service logs
kubectl logs -n kagenti-system -l app=token-exchange-service --tail=100

# Test JWT validation
make test
```

## Related Resources

- [Main README](../README.md) - Architecture overview and quick start
- [Makefile](../Makefile) - Platform-aware build and deployment
- [E2E Tests](../deploy/09-test.sh) - Test scenarios
- [Keycloak Setup](../deploy/03-keycloak-setup.sh) - IdP configuration

## Contributing

When adding new documentation:
1. Use clear, concise language
2. Include diagrams for complex flows
3. Provide concrete examples
4. Link to related documentation
5. Update this README index

## Questions or Feedback?

- File an issue: https://github.com/kagenti/authbridge-waypoint/issues
- Review the test scenarios: `make test`
- Check the comparison table in main README
