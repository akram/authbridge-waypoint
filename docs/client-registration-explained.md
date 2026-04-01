# Client Registration Explained

> **Understanding what client registration does and why it's critical for waypoint token exchange**

## Table of Contents

- [Quick Answer](#quick-answer)
- [What is Client Registration?](#what-is-client-registration)
- [Two Purposes of a Keycloak Client](#two-purposes-of-a-keycloak-client)
- [What the Operator Does](#what-the-operator-does)
- [What Happens WITH Client Registration](#what-happens-with-client-registration)
- [What Happens WITHOUT Client Registration](#what-happens-without-client-registration)
- [Critical Attribute: standard.token.exchange.enabled](#critical-attribute-standardtokenexchangeenabled)
- [Real-World Scenarios](#real-world-scenarios)
- [Troubleshooting](#troubleshooting)

---

## Quick Answer

**Client registration** = Creating an OAuth client in Keycloak for each service (agent/tool).

**What it does:**
- ✅ Gives the service credentials (client_id + client_secret) to authenticate
- ✅ Allows the service to be used as an **audience target** in token exchanges
- ✅ Enables least-privilege tokens (one token per service, not one for all)

**Without registration:**
- ❌ Service cannot authenticate to Keycloak (no credentials)
- ❌ Token exchange **fails** when trying to get tokens for that service
- ❌ ext_authz **DENIES** all requests to unregistered services
- ❌ Complete traffic blockage

---

## What is Client Registration?

In OAuth/OpenID Connect terminology, a **client** is an application or service that uses an identity provider (Keycloak in this case) for authentication.

When we "register a client," we're creating an entry in Keycloak that represents a service with:

```yaml
Client ID: tool-ns/echo-tool                    # ← Identity of the service
Client Secret: abc123secret456                  # ← Password for authentication
Client Type: confidential                       # ← Not public (has a secret)
Enabled: true                                   # ← Active
Service Accounts Enabled: true                  # ← Can authenticate itself
Attributes:
  standard.token.exchange.enabled: "true"       # ← Can be used as audience
```

### Visual Representation

```
Keycloak Realm: kagenti
├── Client: agent-ns/demo-agent
│   ├── client_id: "agent-ns/demo-agent"
│   ├── client_secret: "secret-abc123"
│   └── attributes:
│       └── standard.token.exchange.enabled: true
│
├── Client: tool-ns/echo-tool
│   ├── client_id: "tool-ns/echo-tool"
│   ├── client_secret: "secret-def456"
│   └── attributes:
│       └── standard.token.exchange.enabled: true
│
├── Client: tool-ns/weather-service
│   ├── client_id: "tool-ns/weather-service"
│   ├── client_secret: "secret-ghi789"
│   └── attributes:
│       └── standard.token.exchange.enabled: true
│
└── Client: token-exchange-service
    ├── client_id: "token-exchange-service"
    ├── client_secret: "secret-xyz999"
    └── attributes:
        └── standard.token.exchange.enabled: true
```

---

## Two Purposes of a Keycloak Client

A registered client serves **TWO critical purposes** in the AuthBridge architecture:

### Purpose 1: Initial Authentication (Client as Actor)

The service uses its client credentials to authenticate and get a JWT.

```bash
# Service authenticates to Keycloak
POST /realms/kagenti/protocol/openid-connect/token
Content-Type: application/x-www-form-urlencoded

grant_type=password
&client_id=agent-ns/demo-agent          # ← FROM registration
&client_secret=secret-abc123            # ← FROM registration
&username=alice
&password=alice-password

# Keycloak Response:
{
  "access_token": "eyJhbGc...",
  "token_type": "Bearer",
  "expires_in": 300
}

# JWT payload:
{
  "iss": "https://keycloak.example.com/realms/kagenti",
  "sub": "user-alice",
  "azp": "agent-ns/demo-agent",         # ← Client that got the token
  "aud": [
    "agent-ns/demo-agent",              # ← Can call itself
    "token-exchange-service"            # ← Can request exchanges
  ],
  "exp": 1234567890
}
```

### Purpose 2: Token Exchange Target (Client as Audience)

The service can be specified as the **audience** parameter in RFC 8693 token exchange.

```bash
# token-exchange-service requests token FOR echo-tool
POST /realms/kagenti/protocol/openid-connect/token
Content-Type: application/x-www-form-urlencoded

grant_type=urn:ietf:params:oauth:grant-type:token-exchange
&subject_token=<agent's JWT>
&audience=tool-ns/echo-tool             # ← Client must exist in Keycloak!
&client_id=token-exchange-service
&client_secret=secret-xyz999

# Keycloak validates:
# 1. Does client "tool-ns/echo-tool" exist? ✓
# 2. Does it have standard.token.exchange.enabled=true? ✓
# 3. Is token-exchange-service allowed to request exchanges? ✓

# Keycloak Response:
{
  "access_token": "eyJhbGc...",  # NEW JWT with aud=["tool-ns/echo-tool"]
  "expires_in": 300
}

# New JWT payload:
{
  "iss": "https://keycloak.example.com/realms/kagenti",
  "sub": "user-alice",                  # ← SAME user (preserved)
  "azp": "token-exchange-service",      # ← Issued BY exchange service
  "aud": ["tool-ns/echo-tool"],         # ← NEW audience (narrowed)
  "exp": 1234567890
}
```

---

## What the Operator Does

The **kagenti-operator** automates client registration for every agent/tool workload.

### Without Operator (Manual Registration)

```bash
# Platform team manually creates each client in Keycloak UI or API
# For EACH new service:

# 1. Create client
POST /admin/realms/kagenti/clients
Authorization: Bearer <admin-token>
{
  "clientId": "tool-ns/echo-tool",
  "name": "echo-tool",
  "clientAuthenticatorType": "client-secret",
  "serviceAccountsEnabled": true,
  "attributes": {
    "standard.token.exchange.enabled": "true"
  }
}

# 2. Get generated secret
GET /admin/realms/kagenti/clients/{client-uuid}/client-secret

# 3. Manually create Kubernetes Secret
kubectl create secret generic echo-tool-credentials \
  --from-literal=client-id=tool-ns/echo-tool \
  --from-literal=client-secret=abc123secret \
  -n tool-ns

# 4. Manually mount to pod or configure workload
```

**Pain points:**
- ❌ Manual process for every service
- ❌ Error-prone (typos, missing attributes)
- ❌ No drift reconciliation
- ❌ Scales poorly (100s of services)

### With Operator (Automated Registration)

```yaml
# Platform team deploys workload with label
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo-tool
  namespace: tool-ns
spec:
  template:
    metadata:
      labels:
        kagenti.io/type: tool  # ← THAT'S IT!
    spec:
      containers:
      - name: echo
        image: echo-tool:latest
```

**Operator automatically:**
1. Detects new Deployment with `kagenti.io/type=tool`
2. Reads `authbridge-config` ConfigMap (Keycloak URL, realm)
3. Reads `keycloak-admin-secret` (admin credentials)
4. Calls Keycloak admin API to register client
5. Creates Secret: `kagenti-keycloak-client-credentials-<hash>`
6. Patches pod template annotation for webhook to mount Secret

**Benefits:**
- ✅ Zero manual work per service
- ✅ Consistent configuration
- ✅ Drift reconciliation (operator fixes config if manually changed)
- ✅ Scales to 1000s of services

---

## What Happens WITH Client Registration

### Complete Flow (Working Scenario)

```
┌─────────────────────────────────────────────────────────────────┐
│ PHASE 1: Setup (Operator Runs Once Per Service)                │
└─────────────────────────────────────────────────────────────────┘

Operator detects: Deployment "echo-tool" in tool-ns

1. Operator → Keycloak Admin API
   POST /admin/realms/kagenti/clients
   {
     "clientId": "tool-ns/echo-tool",
     "attributes": { "standard.token.exchange.enabled": "true" }
   }

   Response: { "id": "uuid-123", "secret": "abc123secret" }

2. Operator → Kubernetes API
   Create Secret:
     apiVersion: v1
     kind: Secret
     metadata:
       name: kagenti-keycloak-client-credentials-abc123
       namespace: tool-ns
     data:
       client-id.txt: dG9vbC1ucy9lY2hvLXRvb2w=
       client-secret.txt: YWJjMTIzc2VjcmV0

3. Operator → Kubernetes API
   Patch Deployment:
     metadata:
       annotations:
         kagenti.io/keycloak-client-credentials-secret-name:
           kagenti-keycloak-client-credentials-abc123

4. Webhook mounts Secret to pod at /shared/client-id.txt and /shared/client-secret.txt

┌─────────────────────────────────────────────────────────────────┐
│ PHASE 2: Runtime (Every Request)                               │
└─────────────────────────────────────────────────────────────────┘

User calls Agent, Agent calls Tool:

1. Agent → Keycloak (authenticate)
   POST /realms/kagenti/protocol/openid-connect/token
   {
     client_id: "agent-ns/demo-agent",    # ← FROM registration
     client_secret: "<secret>",           # ← FROM registration
     username: "alice",
     password: "alice-password"
   }

   Response: JWT with aud=["agent-ns/demo-agent", "token-exchange-service"]

2. Agent → Tool
   GET /echo
   Authorization: Bearer <JWT from step 1>

3. Tool Waypoint → token-exchange-service (ext_authz)
   CheckRequest:
   {
     headers: {
       authorization: "Bearer <JWT>",
       ":authority": "echo-tool.tool-ns.svc.cluster.local"
     }
   }

4. token-exchange-service evaluates:
   a. Extract service name: "echo-tool"
   b. Check: aud includes "echo-tool"? NO
   c. Call Keycloak token exchange:

      POST /realms/kagenti/protocol/openid-connect/token
      {
        grant_type: "urn:ietf:params:oauth:grant-type:token-exchange",
        subject_token: "<JWT>",
        audience: "tool-ns/echo-tool",    # ← Client EXISTS ✅
        client_id: "token-exchange-service",
        client_secret: "<secret>"
      }

   d. Keycloak validates:
      ✓ Client "tool-ns/echo-tool" exists
      ✓ Client has standard.token.exchange.enabled=true
      ✓ Subject token is valid

   e. Keycloak returns new JWT with aud=["tool-ns/echo-tool"]

5. token-exchange-service → Waypoint
   CheckResponse:
   {
     status: OK,
     okResponse: {
       headers: [
         { key: "authorization", value: "Bearer <EXCHANGED_JWT>" }
       ]
     }
   }

6. Waypoint → Tool
   GET /echo
   Authorization: Bearer <EXCHANGED_JWT>  # ← Token with aud=["tool-ns/echo-tool"]

7. Tool receives request ✅
   - Can validate: aud includes "tool-ns/echo-tool"
   - Can extract: sub = "user-alice"
```

---

## What Happens WITHOUT Client Registration

### Broken Flow (Service Not Registered)

```
┌─────────────────────────────────────────────────────────────────┐
│ SCENARIO: Tool deployed WITHOUT client registration            │
│ (operator not running, or label missing, or manual deployment) │
└─────────────────────────────────────────────────────────────────┘

Tool "unregistered-tool" deployed in tool-ns:
- NO client in Keycloak
- NO client_id or client_secret
- NO Secret with credentials

┌─────────────────────────────────────────────────────────────────┐
│ ATTEMPT 1: Tool Tries to Authenticate                          │
└─────────────────────────────────────────────────────────────────┘

Tool → Keycloak:
POST /realms/kagenti/protocol/openid-connect/token
{
  client_id: "tool-ns/unregistered-tool",  # ← NOT IN KEYCLOAK
  client_secret: "<????>",                 # ← NO SECRET
  ...
}

Keycloak Response:
{
  "error": "invalid_client",
  "error_description": "Client not found or invalid credentials"
}

Result: Tool CANNOT authenticate ❌
        No JWT = No requests possible

┌─────────────────────────────────────────────────────────────────┐
│ ATTEMPT 2: Agent Calls Unregistered Tool                       │
│ (Assume agent has a valid JWT somehow)                         │
└─────────────────────────────────────────────────────────────────┘

Agent → Unregistered Tool:
GET /api/data
Authorization: Bearer <AGENT_JWT with aud=["agent-ns/demo-agent"]>

Tool Waypoint → token-exchange-service (ext_authz):
CheckRequest:
{
  headers: {
    authorization: "Bearer <AGENT_JWT>",
    ":authority": "unregistered-tool.tool-ns.svc.cluster.local"
  }
}

token-exchange-service evaluates:
1. Extract service name: "unregistered-tool"
2. Check: aud includes "unregistered-tool"? NO
3. Attempt token exchange:

   POST /realms/kagenti/protocol/openid-connect/token
   {
     grant_type: "urn:ietf:params:oauth:grant-type:token-exchange",
     subject_token: "<AGENT_JWT>",
     audience: "tool-ns/unregistered-tool",  # ← CLIENT DOES NOT EXIST
     client_id: "token-exchange-service",
     client_secret: "<secret>"
   }

Keycloak Response:
{
  "error": "invalid_client",
  "error_description": "Client audience not found: tool-ns/unregistered-tool"
}
OR
{
  "error": "access_denied",
  "error_description": "Token exchange not allowed for audience: tool-ns/unregistered-tool"
}

token-exchange-service → Waypoint:
CheckResponse:
{
  status: { code: 7 },  // PERMISSION_DENIED
  deniedResponse: {
    status: { code: 403 },
    body: '{"error":"token exchange failed: Client audience not found"}'
  }
}

Waypoint → Agent:
HTTP/1.1 403 Forbidden
Content-Type: application/json

{"error":"token exchange failed: Client audience not found"}

Result: Request DENIED ❌
        Traffic blocked at waypoint
        Agent receives 403 error

┌─────────────────────────────────────────────────────────────────┐
│ ATTEMPT 3: Manually Register Client (Missing Attribute)        │
└─────────────────────────────────────────────────────────────────┘

Admin manually creates client but forgets attribute:

POST /admin/realms/kagenti/clients
{
  "clientId": "tool-ns/unregistered-tool",
  "serviceAccountsEnabled": true
  // MISSING: "attributes": { "standard.token.exchange.enabled": "true" }
}

Agent → Tool:
GET /api/data
Authorization: Bearer <AGENT_JWT>

Waypoint → token-exchange-service:
... (same as before)

token-exchange-service → Keycloak:
POST /realms/kagenti/protocol/openid-connect/token
{
  audience: "tool-ns/unregistered-tool",  # ← Client EXISTS but...
  ...
}

Keycloak Response:
{
  "error": "access_denied",
  "error_description": "Token exchange not enabled for client: tool-ns/unregistered-tool"
}

token-exchange-service → Waypoint:
CheckResponse: DENIED (403)

Waypoint → Agent:
HTTP/1.1 403 Forbidden
{"error":"token exchange failed: Token exchange not enabled"}

Result: Request DENIED ❌
        Even though client exists, missing attribute blocks exchange
```

---

## Critical Attribute: standard.token.exchange.enabled

This Keycloak client attribute is **THE KEY** to making token exchange work.

### Without the Attribute

```json
// Client registered WITHOUT the attribute
{
  "clientId": "tool-ns/echo-tool",
  "serviceAccountsEnabled": true,
  "directAccessGrantsEnabled": true
  // NO attributes.standard.token.exchange.enabled
}
```

**Effect:**
- ✅ Client can authenticate (get its own JWT)
- ❌ Client **CANNOT** be used as an audience in token exchange
- ❌ All requests to this service will be **DENIED** by ext_authz

**Error:**
```
Token exchange failed: Token exchange not enabled for client: tool-ns/echo-tool
```

### With the Attribute

```json
// Client registered WITH the attribute (operator does this)
{
  "clientId": "tool-ns/echo-tool",
  "serviceAccountsEnabled": true,
  "directAccessGrantsEnabled": true,
  "attributes": {
    "standard.token.exchange.enabled": "true"  // ← CRITICAL
  }
}
```

**Effect:**
- ✅ Client can authenticate
- ✅ Client **CAN** be used as an audience in token exchange
- ✅ token-exchange-service can get tokens scoped to this client
- ✅ Requests succeed

### How to Verify

```bash
# Check if client has the attribute in Keycloak

# 1. Get client UUID
CLIENT_ID="tool-ns/echo-tool"
REALM="kagenti"
ADMIN_TOKEN="<get from Keycloak>"

curl -s "https://keycloak.example.com/admin/realms/$REALM/clients?clientId=$CLIENT_ID" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r '.[0].id'
# Output: abc-123-uuid

# 2. Get client details
CLIENT_UUID="abc-123-uuid"
curl -s "https://keycloak.example.com/admin/realms/$REALM/clients/$CLIENT_UUID" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | jq '.attributes'

# Expected output:
{
  "standard.token.exchange.enabled": "true"
}

# If output is {} or null, token exchange will FAIL
```

---

## Real-World Scenarios

### Scenario 1: Service Deployed Before Operator

```
Timeline:
1. Day 1: Deploy echo-tool manually (no operator running)
2. Day 2: Deploy kagenti-operator
3. Day 3: Agent tries to call echo-tool

What happens:
- echo-tool has NO client in Keycloak
- Operator IS running but hasn't reconciled echo-tool (no label)
- Agent → Tool: 403 Forbidden (token exchange fails)

Fix:
# Add label to trigger operator reconciliation
kubectl patch deployment echo-tool -n tool-ns -p '
spec:
  template:
    metadata:
      labels:
        kagenti.io/type: tool
'

# Operator detects change → registers client → creates Secret
# Restart pods to pick up new Secret mount

kubectl rollout restart deployment/echo-tool -n tool-ns
```

### Scenario 2: Client Registered Without Attribute

```
Situation:
- Admin manually created client in Keycloak
- Forgot to set standard.token.exchange.enabled=true
- Or used old script that doesn't set it

Symptom:
- Service can authenticate and get JWT
- But all cross-service calls fail with 403
- Logs show: "Token exchange not enabled for client"

Fix:
# Option 1: Update client in Keycloak UI
Clients → echo-tool → Attributes
Add: standard.token.exchange.enabled = true
Save

# Option 2: Use admin API
curl -X PUT "https://keycloak.example.com/admin/realms/kagenti/clients/$CLIENT_UUID" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "attributes": {
      "standard.token.exchange.enabled": "true"
    }
  }'

# No pod restart needed (token-exchange-service will retry immediately)
```

### Scenario 3: Client Deleted from Keycloak

```
Situation:
- Operator registered client
- Admin accidentally deleted client in Keycloak UI
- Kubernetes deployment and Secret still exist

Symptom:
- Service has credentials but they're invalid
- Authentication fails: "invalid_client"
- Token exchange fails: "Client audience not found"

Fix:
# Trigger operator reconciliation
kubectl annotate deployment echo-tool -n tool-ns \
  reconcile="$(date +%s)" --overwrite

# Operator detects drift → recreates client in Keycloak
# Secret updated with new credentials
# Restart pods

kubectl rollout restart deployment/echo-tool -n tool-ns
```

### Scenario 4: Wrong Client ID Format

```
Situation:
- Manual registration used different naming convention
- Keycloak client: "echo-tool" (instead of "tool-ns/echo-tool")
- token-exchange-service extracts service name from hostname

What happens:
Agent → echo-tool.tool-ns.svc.cluster.local

token-exchange-service:
1. Extract service name from hostname: "echo-tool"
2. Compute audience: "echo-tool"  # ← NOT "tool-ns/echo-tool"
3. Request token exchange with audience="echo-tool"
4. Keycloak: Client "echo-tool" found ✓
5. Exchange succeeds... BUT
6. Forwarded token has aud=["echo-tool"]
7. If tool validates audience strictly, might reject

Fix:
Use consistent naming:
- Operator default: namespace/name
- Or override via configuration
- Ensure token-exchange-service and operator use same convention
```

---

## Troubleshooting

### Problem: 403 Forbidden on all cross-service calls

**Check 1: Does client exist in Keycloak?**
```bash
REALM="kagenti"
SERVICE="tool-ns/echo-tool"
ADMIN_TOKEN="<token>"

curl -s "https://keycloak.example.com/admin/realms/$REALM/clients?clientId=$SERVICE" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | jq .

# Expected: Array with 1 element
# If []: Client does NOT exist → operator didn't register it
```

**Check 2: Does client have standard.token.exchange.enabled?**
```bash
CLIENT_UUID="<from previous command>"
curl -s "https://keycloak.example.com/admin/realms/$REALM/clients/$CLIENT_UUID" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | jq '.attributes["standard.token.exchange.enabled"]'

# Expected: "true"
# If null or "false": Token exchange DISABLED
```

**Check 3: Are operator logs showing registration?**
```bash
kubectl logs -n kagenti-operator-system deployment/kagenti-operator | grep echo-tool

# Expected:
# Reconciling Deployment tool-ns/echo-tool
# Registered client tool-ns/echo-tool in Keycloak
# Created Secret kagenti-keycloak-client-credentials-abc123

# If no logs: Operator not watching this deployment (check labels)
```

**Check 4: Does Secret exist?**
```bash
kubectl get secret -n tool-ns | grep kagenti-keycloak-client-credentials

# Expected: kagenti-keycloak-client-credentials-abc123
# If none: Operator hasn't created Secret yet (or registration failed)
```

**Check 5: Are credentials mounted in pod?**
```bash
kubectl exec -n tool-ns deployment/echo-tool -- ls -la /shared/

# Expected:
# client-id.txt
# client-secret.txt

# If missing: Webhook didn't mount Secret (check annotations)
```

### Problem: "invalid_client" when service authenticates

**Symptom:**
```
POST /realms/kagenti/protocol/openid-connect/token
Response: {"error":"invalid_client"}
```

**Possible causes:**
1. Client not registered in Keycloak
2. Client credentials (client_id or client_secret) are wrong
3. Client is disabled in Keycloak

**Debug:**
```bash
# 1. Check Secret contents
kubectl get secret -n tool-ns kagenti-keycloak-client-credentials-abc123 -o json | \
  jq -r '.data["client-id.txt"]' | base64 -d
# Output: tool-ns/echo-tool

kubectl get secret -n tool-ns kagenti-keycloak-client-credentials-abc123 -o json | \
  jq -r '.data["client-secret.txt"]' | base64 -d
# Output: abc123secret

# 2. Verify client exists with that client_id
curl -s "https://keycloak.example.com/admin/realms/kagenti/clients?clientId=tool-ns/echo-tool" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | jq '.[0] | {id, clientId, enabled}'

# 3. Get client secret from Keycloak
curl -s "https://keycloak.example.com/admin/realms/kagenti/clients/$CLIENT_UUID/client-secret" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r '.value'

# Compare: Secret in Kubernetes == Secret in Keycloak?
# If different: Operator needs to reconcile (trigger restart)
```

### Problem: Token exchange succeeds but tool rejects token

**Symptom:**
- ext_authz returns 200 OK
- Token exchange succeeds
- But tool returns 401 or 403

**Possible causes:**
1. Tool validates audience strictly, extracted service name mismatch
2. Tool expects different issuer URL
3. Token expired (clock skew)

**Debug:**
```bash
# 1. Capture exchanged token from waypoint logs
kubectl logs -n tool-ns deployment/waypoint | grep "authorization"

# 2. Decode JWT
TOKEN="<from logs>"
echo $TOKEN | cut -d. -f2 | base64 -d 2>/dev/null | jq .

# Check:
# - aud: Should include service name
# - exp: Should be > current timestamp
# - iss: Should match tool's expected issuer

# 3. Check tool logs for validation errors
kubectl logs -n tool-ns deployment/echo-tool | grep -i auth
```

---

## Summary

### Client Registration is Critical Because:

1. **Authentication**: Service needs client_id/client_secret to authenticate to Keycloak
2. **Token Exchange Target**: Service must exist in Keycloak to be used as an audience
3. **Exchange Enablement**: Attribute `standard.token.exchange.enabled=true` is REQUIRED
4. **Credential Provisioning**: Operator creates Secrets that webhook mounts to pods

### Without Client Registration:

| Missing Component | Impact |
|-------------------|--------|
| **No client in Keycloak** | ❌ Service cannot authenticate<br>❌ Token exchange fails (audience not found)<br>❌ All traffic DENIED |
| **No standard.token.exchange.enabled** | ✅ Service CAN authenticate<br>❌ Token exchange fails (not enabled)<br>❌ Cross-service calls DENIED |
| **No Secret in Kubernetes** | ❌ Service has no credentials<br>❌ Cannot authenticate<br>❌ All traffic DENIED |
| **Secret not mounted** | ❌ Service cannot read credentials<br>❌ Cannot authenticate<br>❌ All traffic DENIED |

### The Operator Ensures:

- ✅ Every service has a client in Keycloak
- ✅ Every client has `standard.token.exchange.enabled=true`
- ✅ Every service has a Secret with credentials
- ✅ Every pod has credentials mounted (via webhook)
- ✅ Drift is automatically reconciled
- ✅ Consistent naming and configuration

**Bottom line**: Without client registration, the entire waypoint token exchange architecture **does not work**. The operator automates this critical setup step for every service.
