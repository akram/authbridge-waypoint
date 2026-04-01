# Required Labels for Waypoint Gateway Provisioning

## Critical Requirements

For waypoint gateways to be provisioned and functional in Istio ambient mesh, **two specific labels are REQUIRED**. Without these labels, gateways will remain in `PROGRAMMED: Unknown` status and waypoint pods will not be created.

## 1. Namespace Label: `istio-discovery=enabled`

### Purpose
This label tells istiod (Istio control plane) to watch and reconcile resources in the namespace.

### Symptom Without This Label
```bash
$ kubectl get gateway team1-waypoint -n team1
NAME             CLASS            ADDRESS   PROGRAMMED   AGE
team1-waypoint   istio-waypoint             Unknown      10m

$ kubectl describe gateway team1-waypoint -n team1
Status:
  Conditions:
    Message:  Waiting for controller
    Reason:   Pending
    Status:   Unknown
    Type:     Programmed
```

### How to Apply
```bash
kubectl label namespace <namespace-name> istio-discovery=enabled
```

### Example
```bash
kubectl label namespace team1 istio-discovery=enabled
kubectl label namespace team2 istio-discovery=enabled
```

### Verification
```bash
$ kubectl get ns team1 -o jsonpath='{.metadata.labels.istio-discovery}'
enabled
```

## 2. Gateway Label: `istio.io/waypoint-for`

### Purpose
This label tells the Istio controller what the waypoint is for (typically `all` for namespace-wide waypoints).

### Symptom Without This Label
Even with `istio-discovery=enabled` on the namespace, the gateway may not be programmed correctly.

### How to Apply

**Option A: In YAML manifest**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: team1-waypoint
  namespace: team1
  labels:
    istio.io/waypoint-for: all  # ← REQUIRED
spec:
  gatewayClassName: istio-waypoint
  listeners:
  - name: mesh
    port: 15008
    protocol: HBONE
```

**Option B: Using kubectl**
```bash
kubectl label gateway team1-waypoint -n team1 istio.io/waypoint-for=all
```

### Verification
```bash
$ kubectl get gateway team1-waypoint -n team1 -o jsonpath='{.metadata.labels.istio\.io/waypoint-for}'
all
```

## Complete Example

### Creating a Namespace with Waypoint

```bash
# 1. Create namespace
kubectl create namespace myapp

# 2. Label namespace for ambient mesh AND discovery
kubectl label namespace myapp \
  istio-discovery=enabled \
  istio.io/dataplane-mode=ambient \
  istio.io/use-waypoint=myapp-waypoint

# 3. Create waypoint gateway with required label
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: myapp-waypoint
  namespace: myapp
  labels:
    istio.io/waypoint-for: all  # ← REQUIRED LABEL
spec:
  gatewayClassName: istio-waypoint
  listeners:
  - name: mesh
    port: 15008
    protocol: HBONE
EOF

# 4. Wait for gateway to become PROGRAMMED
kubectl wait --for=condition=Programmed gateway/myapp-waypoint -n myapp --timeout=60s

# 5. Verify waypoint pod was created
kubectl get pods -n myapp -l gateway.networking.k8s.io/gateway-name=myapp-waypoint
```

### Expected Result

```bash
$ kubectl get gateway myapp-waypoint -n myapp
NAME             CLASS            ADDRESS         PROGRAMMED   AGE
myapp-waypoint   istio-waypoint   172.30.24.215   True         30s

$ kubectl get pods -n myapp -l gateway.networking.k8s.io/gateway-name=myapp-waypoint
NAME                              READY   STATUS    RESTARTS   AGE
myapp-waypoint-67c48b5db8-xyz     1/1     Running   0          25s
```

## Why These Labels Are Required

### istio-discovery=enabled

- **Problem**: By default, istiod doesn't watch all namespaces for performance reasons
- **Solution**: This label explicitly opts the namespace into Istio discovery
- **Impact**: Without it, istiod never sees your Gateway resources

### istio.io/waypoint-for=all

- **Problem**: Istio needs to know the scope of the waypoint
- **Solution**: This label defines what traffic the waypoint handles
- **Values**:
  - `all` - All traffic in the namespace (most common)
  - `service/<service-name>` - Traffic for specific service
  - `workload/<workload-name>` - Traffic for specific workload

## Troubleshooting

### Gateway Stuck in "Unknown" Status

1. **Check namespace label:**
   ```bash
   kubectl get ns <namespace> -o jsonpath='{.metadata.labels.istio-discovery}'
   ```
   Should return: `enabled`

2. **Check gateway label:**
   ```bash
   kubectl get gateway <gateway-name> -n <namespace> -o jsonpath='{.metadata.labels.istio\.io/waypoint-for}'
   ```
   Should return: `all` (or appropriate value)

3. **Add missing labels:**
   ```bash
   # Namespace
   kubectl label ns <namespace> istio-discovery=enabled

   # Gateway
   kubectl label gateway <gateway-name> -n <namespace> istio.io/waypoint-for=all
   ```

4. **Verify gateway becomes programmed (should happen within 5-10 seconds):**
   ```bash
   kubectl get gateway <gateway-name> -n <namespace> -w
   ```

### No Waypoint Pod Created

If gateway shows `PROGRAMMED: True` but no pod exists:

1. **Check for waypoint pod:**
   ```bash
   kubectl get pods -n <namespace> -l gateway.networking.k8s.io/gateway-name=<gateway-name>
   ```

2. **Check pod events:**
   ```bash
   kubectl describe gateway <gateway-name> -n <namespace>
   ```

3. **Check istiod logs:**
   ```bash
   kubectl logs -n istio-system deployment/istiod | grep -i <namespace>
   ```

4. **Verify ztunnel is running:**
   ```bash
   kubectl get pods -n istio-ztunnel
   ```

## E2E Test Validation

The e2e test script (`deploy/10-operator-integration-test.sh`) includes automatic validation:

```bash
# Run test - will fail with clear error if labels are missing
./deploy/10-operator-integration-test.sh
```

### Validation Checks Performed

1. ✅ Verifies `istio-discovery=enabled` on both namespaces
2. ✅ Verifies `istio.io/waypoint-for` label on both gateways
3. ✅ Waits for gateways to become `PROGRAMMED: True` (max 60s)
4. ✅ Verifies waypoint pods are created and ready
5. ❌ **Fails with clear error message if any requirement is not met**

### Example Error Message

```bash
[FAIL]  CRITICAL: team1 namespace missing required label: istio-discovery=enabled
        Without this label, istiod will NOT watch the namespace and gateways will remain PROGRAMMED=Unknown
        Fix: kubectl label ns team1 istio-discovery=enabled
```

## References

- **Istio Ambient Mesh Documentation**: https://istio.io/latest/docs/ambient/
- **Gateway API Specification**: https://gateway-api.sigs.k8s.io/
- **E2E Test Script**: `deploy/10-operator-integration-test.sh`
- **E2E Test Documentation**: `docs/operator-integration-e2e.md`

## Summary

| Label | Applied To | Value | Required For |
|-------|-----------|-------|--------------|
| `istio-discovery` | Namespace | `enabled` | istiod to watch namespace |
| `istio.io/waypoint-for` | Gateway | `all` (or specific) | Controller to program gateway |
| `istio.io/dataplane-mode` | Namespace | `ambient` | Ambient mesh mode |
| `istio.io/use-waypoint` | Namespace | `<waypoint-name>` | Traffic routing to waypoint |

**Critical**: The first two labels (`istio-discovery` and `istio.io/waypoint-for`) are absolutely required for waypoint provisioning. Without them, gateways will not be programmed and waypoint pods will not be created.
