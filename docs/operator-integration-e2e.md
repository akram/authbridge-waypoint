# Operator Integration E2E Test

This document describes the end-to-end test that demonstrates the integration of authbridge waypoint with operator-managed client registration and token exchange.

## Overview

The test (`deploy/10-operator-integration-test.sh`) validates the complete integration of:

1. **Token exchange via waypoint** — Transparent token exchange using Istio waypoints and ext_authz
2. **Operator-managed client registration** — Automatic Keycloak client creation and credential provisioning
3. **Multi-team agent communication** — Secure cross-namespace communication with automatic credential management

## Architecture

The test creates two team namespaces with the following setup:

```
   team1-ns                          team2-ns
┌───────────────────┐           ┌───────────────────┐
│ team1-agent       │           │ team2-agent       │
│  (agent)          │──────────>│  (agent)          │
│                   │           │                   │
│ team1-waypoint    │           │ team2-waypoint    │
│  ├─ ext_authz     │           │  ├─ ext_authz     │
│  │  validate JWT  │           │  │  validate JWT  │
│  │  + exchange    │           │  │  + exchange    │
└───────────────────┘           └───────────────────┘
```

### Key Features

- **Automatic Client Registration**: Agents are automatically registered as Keycloak clients by the kagenti-operator
- **Credential Provisioning**: Credentials are created as Kubernetes Secrets with proper ownership references
- **Waypoint-based Token Exchange**: Token exchange happens transparently at the waypoint level
- **Multi-tenancy**: Each team has its own namespace with isolated waypoints

## Prerequisites

Before running the test, ensure the following are deployed:

### 1. Keycloak

```bash
# Verify Keycloak is running
kubectl get pods -n keycloak -l app=keycloak

# Ensure keycloak-admin-secret exists
kubectl get secret keycloak-admin-secret -n keycloak
```

### 2. Kagenti Operator

The operator must be deployed with client registration enabled:

```bash
# Verify operator is running
kubectl get pods -n kagenti-operator-system

# Check operator configuration
kubectl get deployment kagenti-operator-controller-manager -n kagenti-operator-system -o yaml | grep -A 5 args:
```

Required operator flags:
- `--enable-operator-client-registration=true`
- `--spire-trust-domain=<your-trust-domain>` (if using SPIRE)

### 3. Kagenti Webhook

The webhook must support operator-managed credentials:

```bash
# Verify webhook is running
kubectl get pods -n kagenti-webhook-system

# Check webhook configuration
kubectl get mutatingwebhookconfiguration kagenti-webhook-mutating-webhook-configuration
```

### 4. Istio Ambient Mesh

The cluster must have Istio ambient mesh configured with the token exchange extension provider:

```bash
# Verify Istio is installed
kubectl get pods -n istio-system

# Check for token-exchange-service
kubectl get pods -n kagenti-system -l app=token-exchange-service

# Verify extension provider configuration
kubectl get configmap istio -n istio-system -o yaml | grep -A 10 extensionProviders
```

The Istio mesh config should include:

```yaml
extensionProviders:
- name: kagenti-token-exchange
  envoyExtAuthzGrpc:
    service: token-exchange-service.kagenti-system.svc.cluster.local
    port: 9000
```

### 5. Test Images

The following images must be available in your cluster:

- `image-registry.openshift-image-registry.svc:5000/kagenti-images/demo-agent:latest`
- `image-registry.openshift-image-registry.svc:5000/kagenti-images/echo-tool:latest`

Build and push these images from the authbridge-waypoint repository:

```bash
# Build images
make build-images

# Push to registry (adjust for your cluster)
make push-images
```

## Running the Test

### Basic Usage

```bash
# Run the test with default settings
./deploy/10-operator-integration-test.sh
```

### With ROSA/OpenShift

If running on ROSA or OpenShift with an external Keycloak route:

```bash
# Set Keycloak URL to the external route
export KC_URL="https://keycloak-keycloak.apps.<cluster-domain>"

# Run the test
./deploy/10-operator-integration-test.sh
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `KC_URL` | `http://localhost:18080` | Keycloak base URL |
| `KEYCLOAK_SVC` | `keycloak-service` | Keycloak service name |
| `KEYCLOAK_NS` | `keycloak` | Keycloak namespace |
| `OPERATOR_NS` | `kagenti-operator-system` | Operator namespace |
| `WEBHOOK_NS` | `kagenti-webhook-system` | Webhook namespace |
| `SKIP_CLEANUP` | `false` | Skip cleanup for debugging |

### Debug Mode

To keep test resources for debugging:

```bash
export SKIP_CLEANUP=true
./deploy/10-operator-integration-test.sh
```

## Test Flow

The test performs the following steps:

### 1. Setup Phase

1. Creates `team1` and `team2` namespaces with ambient mesh labels
2. Configures `authbridge-config` and `keycloak-admin-secret` in both namespaces
3. Deploys waypoint gateways for each team
4. Configures AuthorizationPolicy for token exchange
5. Deploys agent workloads in each namespace

### 2. Operator Registration Test

1. Waits for operator to reconcile agent deployments
2. Verifies Keycloak client credentials secrets are created
3. Checks secret ownership references point to the correct Deployment
4. Validates pod template annotations reference the credentials secrets
5. Confirms client-id.txt and client-secret.txt keys exist in secrets

### 3. Keycloak Client Verification

1. Obtains admin token from Keycloak
2. Queries Keycloak API to verify clients were created
3. Validates client IDs match expected format: `<namespace>/<workload-name>`

### 4. Waypoint Configuration Test

1. Verifies waypoint gateways are created and Programmed
2. Checks gatewayClassName is set to `istio-waypoint`
3. Validates AuthorizationPolicy resources reference correct providers
4. Confirms token exchange extension provider is configured

### 5. Cross-Team Communication Test

1. Obtains token for team1-agent using operator-provisioned credentials
2. Makes request from team1-agent to team2-agent
3. Verifies HTTP 200 response
4. Validates token was exchanged (different from original)
5. Confirms exchanged token has correct audience claim

## Expected Results

A successful test run will show:

```
========================================
Test Summary
========================================

[INFO]  Integration Test Results:
        ✓ Operator-managed client registration
        ✓ Automatic Keycloak client creation
        ✓ Credential secret provisioning
        ✓ Waypoint configuration
        ✓ Token exchange for cross-team communication

==============================
  RESULTS: X passed, 0 failed
==============================

[INFO]  All tests passed! ✓
```

## Troubleshooting

### Operator Not Creating Secrets

If secrets are not being created:

1. Check operator logs:
   ```bash
   kubectl logs -n kagenti-operator-system -l control-plane=controller-manager --tail=50
   ```

2. Verify operator is enabled for client registration:
   ```bash
   kubectl get deployment kagenti-operator-controller-manager -n kagenti-operator-system -o yaml | grep enable-operator-client-registration
   ```

3. Check for required configuration in agent namespaces:
   ```bash
   kubectl get configmap authbridge-config -n team1
   kubectl get secret keycloak-admin-secret -n team1
   ```

### Waypoint Not Exchanging Tokens

If tokens are not being exchanged:

1. Check token-exchange-service logs:
   ```bash
   kubectl logs -n kagenti-system -l app=token-exchange-service --tail=50
   ```

2. Verify waypoint configuration:
   ```bash
   kubectl get gateway team1-waypoint -n team1 -o yaml
   kubectl get authorizationpolicy team1-waypoint-token-exchange -n team1 -o yaml
   ```

3. Check Istio extension provider configuration:
   ```bash
   kubectl get configmap istio -n istio-system -o yaml | grep -A 10 kagenti-token-exchange
   ```

### Authentication Failures

If authentication fails:

1. Verify Keycloak clients exist:
   ```bash
   # Port-forward to Keycloak
   kubectl port-forward -n keycloak svc/keycloak-service 18080:8080

   # Get admin token
   curl -X POST http://localhost:18080/realms/kagenti/protocol/openid-connect/token \
     -d grant_type=client_credentials \
     -d client_id=admin-cli \
     -d client_secret=admin-secret

   # List clients
   curl -H "Authorization: Bearer <admin-token>" \
     http://localhost:18080/admin/realms/kagenti/clients
   ```

2. Check credentials secret content:
   ```bash
   kubectl get secret <secret-name> -n team1 -o jsonpath='{.data.client-id\.txt}' | base64 -d
   kubectl get secret <secret-name> -n team1 -o jsonpath='{.data.client-secret\.txt}' | base64 -d
   ```

### Debugging Resources

Commands to inspect test resources:

```bash
# View all resources in test namespaces
kubectl get all -n team1
kubectl get all -n team2

# Check pod logs
kubectl logs -n team1 -l app=team1-agent
kubectl logs -n team2 -l app=team2-agent

# Describe deployments for webhook annotations
kubectl describe deployment team1-agent -n team1
kubectl describe deployment team2-agent -n team2

# View secrets
kubectl get secrets -n team1
kubectl get secrets -n team2

# Check waypoint status
kubectl get gateway team1-waypoint -n team1 -o yaml
kubectl get gateway team2-waypoint -n team2 -o yaml
```

## Cleanup

The test automatically cleans up resources unless `SKIP_CLEANUP=true` is set.

Manual cleanup:

```bash
kubectl delete namespace team1 team2
```

## Integration with CI/CD

To run this test in a CI pipeline:

```yaml
# Example GitHub Actions step
- name: Run operator integration test
  run: |
    export KC_URL="${{ secrets.KEYCLOAK_URL }}"
    ./deploy/10-operator-integration-test.sh
```

## Related Documentation

- [Operator-managed Client Registration](../kagenti-operator/docs/operator-managed-client-registration.md)
- [Authbridge Waypoint README](../README.md)
- [Token Exchange Service](./token-exchange-service.md)
