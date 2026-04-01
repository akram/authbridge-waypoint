# SKIP_CLEANUP Mode - Example Output

This document shows the enhanced output when running the e2e test with `SKIP_CLEANUP=true`.

## Usage

```bash
export SKIP_CLEANUP=true
./deploy/10-operator-integration-test.sh
```

## Example Output at Cleanup Phase

When the test completes with `SKIP_CLEANUP=true`, you'll see:

```
========================================
Resources Preserved for Inspection
========================================

[INFO]  Cleanup skipped (SKIP_CLEANUP=true)

[INFO]  Test resources have been preserved. Use the following commands to inspect:

# View all pods in both namespaces
kubectl get pods -n team1 -o wide
kubectl get pods -n team2 -o wide

# Check pod details and injected containers/volumes
kubectl describe pod -n team1 -l app=team1-agent
kubectl describe pod -n team2 -l app=team2-agent

# View operator-created secrets
kubectl get secrets -n team1 | grep kagenti-keycloak
kubectl get secrets -n team2 | grep kagenti-keycloak

# Inspect secret contents
kubectl get secret -n team1 $(kubectl get secrets -n team1 -o name | grep kagenti-keycloak) -o yaml

# Check deployment annotations (operator adds these)
kubectl get deployment team1-agent -n team1 -o jsonpath='{.spec.template.metadata.annotations}' | jq
kubectl get deployment team2-agent -n team2 -o jsonpath='{.spec.template.metadata.annotations}' | jq

# View waypoint gateways
kubectl get gateway -n team1
kubectl get gateway -n team2

# Check authorization policies
kubectl get authorizationpolicy -n team1
kubectl get authorizationpolicy -n team2

# View operator logs for reconciliation
kubectl logs -n kagenti-system -l control-plane=controller-manager --tail=50 | grep -i team

# Verify Keycloak clients were created (requires port-forward)
kubectl port-forward -n keycloak svc/keycloak-service 18080:8080 &
# Then query Keycloak API:
curl -s -X POST http://localhost:18080/realms/kagenti/protocol/openid-connect/token \
  -d 'grant_type=client_credentials' -d 'client_id=admin-cli' -d 'client_secret=admin-secret' | jq -r '.access_token'

[INFO]  When done inspecting, clean up with:
kubectl delete namespace team1 team2
```

## Example Output at Test Completion

After all tests pass:

```
========================================
What to Check for Sidecar Injection
========================================

[INFO]  The test resources are still running. Here's what to verify:

1. Check if webhook injected sidecars into pods:
   kubectl get pods -n team1 -o jsonpath='{.items[*].spec.containers[*].name}'
   kubectl get pods -n team2 -o jsonpath='{.items[*].spec.containers[*].name}'
   Expected: Should show multiple containers if webhook injected sidecars

2. Verify operator-provisioned credentials are mounted:
   kubectl exec -n team1 deploy/team1-agent -- ls -la /shared/ 2>/dev/null || echo 'No /shared mount'
   Expected: Should see client-id.txt and client-secret.txt if webhook mounted them

3. Check pod volumes (should include operator secret):
   kubectl get pod -n team1 -l app=team1-agent -o jsonpath='{.items[0].spec.volumes[*].name}' | tr ' ' '\n'
   Expected: Should include volume named like 'kagenti-keycloak-client-credentials-*'

4. View complete pod YAML to see injection:
   kubectl get pod -n team1 -l app=team1-agent -o yaml | less
   Look for: initContainers, sidecar containers, volume mounts, annotations

5. Check if pods are using the waypoint:
   kubectl get pods -n team1 -o yaml | grep -A 5 'istio.io/use-waypoint'
   Expected: Should show waypoint configuration

6. Verify Keycloak client creation (check operator logs):
   kubectl logs -n kagenti-system -l control-plane=controller-manager --tail=100 | grep 'team1-agent\|team2-agent'
   Expected: Should show successful client creation messages

7. Test token acquisition using operator-provisioned credentials:
   # Get credentials from secret
   CLIENT_ID=$(kubectl get secret -n team1 $(kubectl get secrets -n team1 -o name | grep kagenti-keycloak) -o jsonpath='{.data.client-id\.txt}' | base64 -d)
   CLIENT_SECRET=$(kubectl get secret -n team1 $(kubectl get secrets -n team1 -o name | grep kagenti-keycloak) -o jsonpath='{.data.client-secret\.txt}' | base64 -d)
   # Get token from Keycloak
   kubectl port-forward -n keycloak svc/keycloak-service 18080:8080 &
   curl -X POST http://localhost:18080/realms/kagenti/protocol/openid-connect/token \
     -d "grant_type=client_credentials" -d "client_id=$CLIENT_ID" -d "client_secret=$CLIENT_SECRET"

[INFO]  Summary of what the operator + webhook did:
✓ Operator detected deployments with label 'kagenti.io/type: agent'
✓ Operator created Keycloak clients (team1/team1-agent, team2/team2-agent)
✓ Operator provisioned credential Secrets with ownership references
✓ Operator annotated pod templates with secret names
✓ Webhook (should have) injected sidecars and mounted credentials
✓ Waypoints configured for token exchange
```

## What This Helps You Verify

### Operator-Managed Client Registration
- ✅ Secrets created with correct naming pattern
- ✅ Secrets have proper ownership references to Deployments
- ✅ Pod templates have the annotation pointing to the secret

### Webhook Sidecar Injection
- ✅ Multiple containers in pod (agent + envoy-proxy + spiffe-helper)
- ✅ Init container (proxy-init) for iptables setup
- ✅ Operator secret mounted as a volume
- ✅ Credentials accessible at `/shared/client-id.txt` and `/shared/client-secret.txt`

### Waypoint Configuration
- ✅ Gateway resources created
- ✅ Authorization policies configured
- ✅ Pods labeled/annotated to use waypoints

## Real Example from Test Execution

Based on actual test run:

```bash
# Viewing injected containers
$ kubectl get pod -n team1 -l app=team1-agent -o jsonpath='{.items[0].spec.containers[*].name}'
agent envoy-proxy spiffe-helper

# Checking init containers
$ kubectl get pod -n team1 -l app=team1-agent -o jsonpath='{.items[0].spec.initContainers[*].name}'
proxy-init

# Inspecting volumes
$ kubectl get pod -n team1 -l app=team1-agent -o jsonpath='{.items[0].spec.volumes[*].name}' | tr ' ' '\n' | grep kagenti
kagenti-keycloak-client-credentials-495542128221c866
```

## Cleanup When Done

After you've inspected everything:

```bash
kubectl delete namespace team1 team2
```

This removes all test resources including:
- Namespaces (team1, team2)
- Deployments
- Services
- ServiceAccounts
- Secrets
- Gateways
- AuthorizationPolicies
- Pods
