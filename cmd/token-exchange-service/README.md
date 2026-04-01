# Token Exchange Service

The **token-exchange-service** is the central component of the authbridge-waypoint architecture. It provides transparent JWT validation and RFC 8693 token exchange via two interfaces:

1. **Envoy ext_authz gRPC v3** — for Istio waypoints (ambient mesh mode)
2. **HTTP forward proxy** — via `HTTP_PROXY` env var (no mesh required)

Both interfaces share the same authorization logic: if a token's `aud` claim includes the destination service name, pass through; otherwise, exchange the token via Keycloak to get a token scoped to that service.

## Architecture

```
┌────────────────────────────────────────────────────────────────────┐
│                   token-exchange-service                           │
│                                                                    │
│  ┌──────────────────────┐        ┌──────────────────────┐         │
│  │  gRPC ext_authz      │        │  HTTP Proxy          │         │
│  │  :9090               │        │  :8080               │         │
│  │  (waypoint mode)     │        │  (HTTP_PROXY mode)   │         │
│  └──────────┬───────────┘        └──────────┬───────────┘         │
│             │                               │                     │
│             └───────────┬───────────────────┘                     │
│                         ▼                                         │
│              ┌──────────────────────┐                             │
│              │  Shared Auth Logic   │                             │
│              │                      │                             │
│              │  1. Extract JWT      │                             │
│              │  2. Validate (JWKS)  │                             │
│              │  3. Check aud claim  │                             │
│              │  4. Exchange if needed │                           │
│              └──────────┬───────────┘                             │
│                         │                                         │
│              ┌──────────┴───────────┐                             │
│              │                      │                             │
│              ▼                      ▼                             │
│       ┌─────────────┐        ┌─────────────┐                     │
│       │ JWKS Cache  │        │ Token Cache │                     │
│       │ (15m refresh)│        │ (TTL-30s)   │                     │
│       └─────────────┘        └─────────────┘                     │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    Keycloak (kagenti realm)
                    - JWKS endpoint (certs)
                    - Token exchange (RFC 8693)
```

## How It Works

### Authorization Decision Logic

For each incoming request, the service:

1. **Extracts** the `Authorization` header
   - If missing and path matches bypass patterns → allow
   - If missing and path not in bypass → deny (401)

2. **Validates** the JWT
   - Signature verification using cached JWKS keys
   - Issuer check (must match `ISSUER_URL`)
   - Expiration check
   - If invalid → deny with specific error

3. **Checks audience** (`aud` claim)
   - Extracts destination service name from `Host` header
   - Example: `echo-tool.tool-ns.svc.cluster.local` → `echo-tool`

4. **Makes decision**:
   ```
   if aud includes destination service:
       → ALLOW (pass through original token)
   else:
       → EXCHANGE via Keycloak RFC 8693
       → ALLOW with replacement token (aud=destination)
   ```

### Token Exchange Flow

When exchange is needed:

```
1. Check cache: (subject_token_hash, audience) → cached token?
   ├─ HIT: return cached token (if not expired)
   └─ MISS: proceed to exchange

2. Call Keycloak token exchange endpoint:
   POST /realms/kagenti/protocol/openid-connect/token

   grant_type=urn:ietf:params:oauth:grant-type:token-exchange
   subject_token=<original JWT>
   subject_token_type=urn:ietf:params:oauth:token-type:access_token
   audience=<destination-service-name>
   client_id=token-exchange-service
   client_secret=<CLIENT_SECRET>

3. Keycloak validates:
   - Is token-exchange-service allowed? (standard.token.exchange.enabled)
   - Is subject_token valid?
   - Is token-exchange-service in subject_token.aud?

4. Keycloak returns new token:
   {
     "access_token": "eyJ...",  // aud=destination, azp=token-exchange-service
     "expires_in": 300
   }

5. Cache the result (TTL = expires_in - 30s)

6. Return new token
```

## Configuration

All configuration is via environment variables:

### Keycloak Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `KEYCLOAK_URL` | `http://keycloak-service.keycloak.svc.cluster.local:8080` | Internal Keycloak URL for API calls (JWKS, exchange) |
| `ISSUER_URL` | (same as `KEYCLOAK_URL`) | External issuer URL in JWT `iss` claim. **Must match** what Keycloak puts in tokens. |
| `REALM` | `kagenti` | Keycloak realm name |
| `CLIENT_ID` | `token-exchange-service` | Service's Keycloak client ID |
| `CLIENT_SECRET` | **(required)** | Service's Keycloak client secret |

### Network Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `LISTEN_ADDR` | `:9090` | gRPC ext_authz listen address |
| `PROXY_LISTEN_ADDR` | (disabled) | HTTP forward proxy listen address (e.g., `:8080`). If empty, proxy is disabled. |

### Bypass Paths

| Variable | Default | Description |
|----------|---------|-------------|
| `BYPASS_INBOUND_PATHS` | `/.well-known/*,/healthz,/readyz,/livez` | Comma-separated list of path patterns that skip auth when no `Authorization` header is present. Uses `path.Match` syntax. |

## Deployment Example

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: token-exchange-service
  namespace: kagenti-system
spec:
  replicas: 1
  template:
    spec:
      containers:
      - name: token-exchange-service
        image: localhost:5000/token-exchange-service:latest
        ports:
        - containerPort: 9090
          name: grpc
        - containerPort: 8080
          name: http-proxy
        env:
        - name: KEYCLOAK_URL
          value: "http://keycloak-service.keycloak.svc.cluster.local:8080"
        - name: ISSUER_URL
          value: "http://keycloak.localtest.me:8080"
        - name: REALM
          value: "kagenti"
        - name: CLIENT_ID
          value: "token-exchange-service"
        - name: CLIENT_SECRET
          valueFrom:
            secretKeyRef:
              name: token-exchange-credentials
              key: CLIENT_SECRET
        - name: LISTEN_ADDR
          value: ":9090"
        - name: PROXY_LISTEN_ADDR
          value: ":8080"
        readinessProbe:
          grpc:
            port: 9090
        livenessProbe:
          grpc:
            port: 9090
```

## Dual Interface: gRPC vs HTTP Proxy

### 1. gRPC ext_authz (Waypoint Mode)

Used by Istio waypoints via Envoy's ext_authz filter.

**Envoy configuration** (via Istio extension provider):
```yaml
extensionProviders:
- name: kagenti-token-exchange
  envoyExtAuthzGrpc:
    service: token-exchange-service.kagenti-system.svc.cluster.local
    port: 9090
```

**Request flow**:
```
Waypoint → ext_authz gRPC call → token-exchange-service:9090
         → Check(CheckRequest)
         ← CheckResponse (OK + headers_to_set)
```

**Protocol**: `envoy.service.auth.v3.Authorization/Check`

**Advantages**:
- Native Istio/Envoy integration
- No changes to workload pods
- Declarative policy via `AuthorizationPolicy`
- Works with ambient mesh (no sidecars)

### 2. HTTP Forward Proxy (No-Mesh Mode)

Used by workloads via `HTTP_PROXY` environment variable.

**Workload configuration**:
```yaml
env:
- name: HTTP_PROXY
  value: "http://token-exchange-service.kagenti-system.svc.cluster.local:8080"
- name: NO_PROXY
  value: "localhost,127.0.0.1"
```

**Request flow**:
```
Workload → HTTP CONNECT → token-exchange-service:8080
         → Proxy validates/exchanges
         → Proxy forwards to destination with new token
```

**Advantages**:
- No mesh required
- Works in any namespace (ambient or not)
- Standard HTTP proxy protocol
- Same auth logic as gRPC mode

## Caching Strategy

### JWKS Cache

- **Purpose**: Store Keycloak's public keys for JWT signature verification
- **Refresh**: Background job every **15 minutes**
- **Keyed by**: `kid` (Key ID from JWT header)
- **Storage**: In-memory `map[string]*rsa.PublicKey`

**Why cache?**
- Avoids calling Keycloak's `/certs` endpoint on every request
- JWKS keys rarely change (only on key rotation)
- Significant performance improvement

### Token Cache

- **Purpose**: Store exchanged tokens to avoid repeated Keycloak calls
- **TTL**: `expires_in - 30 seconds` (30s safety margin)
- **Keyed by**: SHA-256 hash of `(subject_token, audience)`
- **Eviction**: Background job every **60 seconds** removes expired entries
- **Storage**: In-memory `map[string]cachedToken`

**Why cache?**
- Same user calling same tool repeatedly = 1 exchange instead of N
- Exchanged tokens are valid for 5 minutes (Keycloak default)
- Reduces load on Keycloak
- Improves latency (cached: <1ms, exchange: ~50-100ms)

**Cache key rationale**:
- `subject_token` identifies the user/agent
- `audience` identifies the destination tool
- Hash prevents unbounded key size (original tokens are ~1-2KB)

## Performance Characteristics

### Latency

| Scenario | Latency | Notes |
|----------|---------|-------|
| Token cache hit | <1ms | In-memory lookup |
| JWKS cache hit, token cache miss | 50-100ms | Keycloak token exchange call |
| JWKS cache miss | +10-20ms | Fetch JWKS from Keycloak |
| First request (cold start) | 100-150ms | JWKS fetch + token exchange |

### Throughput

- **gRPC**: Handles thousands of concurrent requests (Go's `grpc.Server`)
- **HTTP Proxy**: Limited by Go's `http.Server` default concurrency
- **Bottleneck**: Keycloak token exchange endpoint (mitigated by caching)

### Memory

- **JWKS cache**: ~10-20 keys × ~2KB = ~40KB
- **Token cache**: Depends on usage, typically <10MB for hundreds of cached tokens
- **Base process**: ~50-100MB

## Error Handling

The service returns specific error messages for debugging:

| Error | HTTP Code | Message | Cause |
|-------|-----------|---------|-------|
| No auth header (non-bypass path) | 401 | `no Authorization header` | Missing `Authorization` header on protected path |
| Malformed JWT | 401 | `token is malformed: ...` | Invalid JWT structure |
| Invalid signature | 401 | `invalid token: ...` | JWT signature verification failed |
| Expired token | 401 | `token expired` | JWT `exp` claim in the past |
| Invalid issuer | 401 | `invalid issuer: got X, want Y` | JWT `iss` doesn't match `ISSUER_URL` |
| Exchange failed | 403 | `token exchange failed: ...` | Keycloak rejected the exchange request |

**Example error response** (via demo-agent):
```json
{
  "agent_action": "called echo-tool",
  "tool_status": 401,
  "tool_response_raw": {
    "error": "invalid token: token is expired"
  }
}
```

## Bypass Paths

Certain paths are allowed **without authentication** when no `Authorization` header is present. This enables health checks and public metadata endpoints.

**Default bypass paths**:
- `/.well-known/*` - Agent/tool metadata (e.g., `/.well-known/agent.json`)
- `/healthz` - Kubernetes health checks
- `/readyz` - Kubernetes readiness checks
- `/livez` - Kubernetes liveness checks

**Override** via `BYPASS_INBOUND_PATHS`:
```bash
export BYPASS_INBOUND_PATHS="/.well-known/*,/healthz,/public/*"
```

**Pattern matching**: Uses Go's `path.Match` (same as shell globbing)
- `*` matches any sequence of characters
- `?` matches a single character
- Example: `/api/v*/public` matches `/api/v1/public`, `/api/v2/public`

**Important**: Bypass only applies when **no Authorization header** is present. If a header exists, validation always occurs (and may fail).

## Audience Detection Convention

The service uses a **convention-over-configuration** approach for determining the destination service name:

```
Host header: echo-tool.tool-ns.svc.cluster.local:8080
                ↓
Service name: echo-tool (first segment before first dot)
                ↓
Expected audience: token.aud includes "echo-tool"
```

**This convention requires**:
1. Keycloak client ID matches Kubernetes service name
2. Service calls use FQDN (not IP addresses)

**For external services** (e.g., `api.github.com`):
- First segment: `api` (not a Keycloak client)
- Would need explicit mapping (not yet implemented)
- Current behavior: exchange will fail (Keycloak doesn't know audience `api`)

## Building and Running

### Build
```bash
CGO_ENABLED=0 go build -o bin/token-exchange-service ./cmd/token-exchange-service
```

### Run locally
```bash
export CLIENT_SECRET=exchange-secret
export KEYCLOAK_URL=http://localhost:8080
export ISSUER_URL=http://localhost:8080

./bin/token-exchange-service
```

### Docker
```bash
docker build -t token-exchange-service:latest \
  --build-arg SERVICE=token-exchange-service \
  -f Dockerfile .
```

## Testing

### Test JWT validation
```bash
# Invalid token
curl -H "Authorization: Bearer invalid-token" \
  localhost:9090
# → Should fail validation

# Valid token (from Keycloak)
TOKEN=$(curl -sf -X POST http://localhost:8080/realms/kagenti/protocol/openid-connect/token \
  -d "grant_type=client_credentials&client_id=demo-agent&client_secret=agent-secret" | jq -r '.access_token')

# Call via gRPC requires Envoy (test via demo-agent instead)
```

### Test via demo-agent
```bash
# Deploy the PoC
make up

# Run E2E tests (includes token exchange validation)
make test
```

## Troubleshooting

### "invalid issuer" error

**Symptom**: `invalid issuer: got http://localhost:18080, want https://keycloak.example.com`

**Cause**: Token's `iss` claim doesn't match `ISSUER_URL`

**Fix**: Ensure `ISSUER_URL` matches what Keycloak puts in tokens
- Check token: `echo $TOKEN | cut -d. -f2 | base64 -d | jq .iss`
- Set `ISSUER_URL` to match

### "Client not allowed to exchange"

**Symptom**: Token exchange returns 400 with this error

**Cause**: `standard.token.exchange.enabled` not set on `token-exchange-service` client

**Fix**: Run Keycloak setup script
```bash
bash deploy/03-keycloak-setup.sh
```

### "not in subject token audience"

**Symptom**: Token exchange fails with this error

**Cause**: Original token's `aud` doesn't include `token-exchange-service`

**Fix**: Add audience mapper to the agent client (see `deploy/03-keycloak-setup.sh`)

### JWKS fetch failed

**Symptom**: `JWKS refresh failed: ...` in logs

**Cause**: Can't reach Keycloak's `/certs` endpoint

**Fix**:
- Check `KEYCLOAK_URL` is correct
- Verify network connectivity to Keycloak
- Check Keycloak is running

### High latency

**Symptom**: Requests taking >100ms consistently

**Possible causes**:
1. Token cache disabled or too small TTL
2. Keycloak overloaded (check Keycloak metrics)
3. Network latency to Keycloak

**Debug**:
```bash
# Check cache hit rate (look for "using cached token" in logs)
kubectl logs -n kagenti-system -l app=token-exchange-service --tail=100 | grep cached

# Check Keycloak response times
kubectl logs -n keycloak -l app=keycloak --tail=100 | grep token
```

## Security Considerations

1. **CLIENT_SECRET protection**
   - Never commit to git
   - Use Kubernetes Secrets
   - Rotate periodically

2. **ISSUER_URL validation**
   - Must match tokens exactly
   - Prevents token forgery from other issuers

3. **Token caching**
   - Cached tokens survive service restart (in-memory only)
   - Consider Redis for persistence
   - TTL safety margin prevents using expired tokens

4. **Bypass paths**
   - Only allow public paths
   - Validate that bypass is intentional
   - Don't bypass sensitive endpoints

5. **Error messages**
   - Specific errors aid debugging
   - Don't leak sensitive info (no token contents in logs)
   - Consider rate limiting on auth failures (not implemented)

## Future Enhancements

- [ ] Persistent cache (Redis)
- [ ] Metrics (Prometheus)
- [ ] Distributed tracing (OpenTelemetry)
- [ ] External service audience mapping (override convention)
- [ ] mTLS to Keycloak
- [ ] Token introspection (validate with Keycloak on cache miss)
- [ ] Audience claim validation levels (strict vs permissive)
- [ ] Rate limiting per client

## Related Documentation

- [Main README](../../README.md) - Architecture overview and PoC setup
- [Keycloak Setup](../../deploy/03-keycloak-setup.sh) - Keycloak configuration script
- [E2E Tests](../../deploy/09-test.sh) - Test scenarios
