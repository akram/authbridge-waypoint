# Enabling ztunnel for Istio Ambient Mesh

This guide explains how to enable ztunnel (the L4 proxy) required for Istio ambient mesh waypoint functionality.

## Current Cluster Status

Your cluster has:
- ✅ Istio version: **1.28.4** (OpenShift Service Mesh variant)
- ✅ Ambient enabled: `PILOT_ENABLE_AMBIENT=true`
- ✅ Gateway class: `istio-waypoint` available
- ❌ **ztunnel DaemonSet**: MISSING (this is what we need to install)

## What is ztunnel?

**ztunnel** (zero-trust tunnel) is the node proxy component of Istio ambient mesh that:
- Runs as a DaemonSet (one pod per node)
- Handles L4 (TCP) traffic interception and forwarding
- Provides mTLS between workloads
- Routes traffic to waypoint gateways for L7 processing
- Required for ambient mesh to function

## Installation Methods

### Method 1: Using Helm (Recommended)

This is the standard way to install ztunnel for ambient mesh.

#### Step 1: Add Istio Helm Repository

```bash
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update
```

#### Step 2: Install Istio CNI (if not already installed)

Ambient mesh requires the Istio CNI plugin for traffic redirection:

```bash
# Check if CNI is already installed
kubectl get daemonset -n istio-system istio-cni-node

# If not found, install it
helm install istio-cni istio/cni \
  -n istio-system \
  --version 1.28.4 \
  --set profile=ambient \
  --wait
```

#### Step 3: Install ztunnel

```bash
helm install ztunnel istio/ztunnel \
  -n istio-system \
  --version 1.28.4 \
  --set profile=ambient \
  --wait
```

#### Step 4: Verify Installation

```bash
# Check ztunnel DaemonSet
kubectl get daemonset ztunnel -n istio-system

# Check ztunnel pods (should be one per node)
kubectl get pods -n istio-system -l app=ztunnel

# Check logs
kubectl logs -n istio-system -l app=ztunnel --tail=20
```

Expected output:
```
NAME      DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
ztunnel   3         3         3       3            3           <none>          2m
```

### Method 2: Using istioctl (Alternative)

If you prefer using istioctl:

#### Step 1: Install istioctl

```bash
# Download istioctl matching your Istio version
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.28.4 sh -

# Add to PATH
cd istio-1.28.4
export PATH=$PWD/bin:$PATH

# Verify version
istioctl version
```

#### Step 2: Install ztunnel Component

```bash
# Install CNI (if not already installed)
istioctl install --set profile=ambient --set components.cni.enabled=true -y

# Install ztunnel
istioctl install --set profile=ambient --set components.ztunnel.enabled=true -y
```

### Method 3: Using Manifests (Manual)

If Helm and istioctl are not available, you can apply manifests directly:

#### Step 1: Generate Manifests

```bash
# Using Helm template (doesn't install, just generates YAML)
helm template ztunnel istio/ztunnel \
  -n istio-system \
  --version 1.28.4 \
  --set profile=ambient \
  > ztunnel-manifests.yaml
```

#### Step 2: Review and Apply

```bash
# Review the manifests
less ztunnel-manifests.yaml

# Apply to cluster
kubectl apply -f ztunnel-manifests.yaml
```

## For OpenShift / Red Hat Service Mesh

Since your cluster is using Red Hat registry images, you might need to use Red Hat's installation method:

### Option A: Red Hat Service Mesh Operator

If using the Red Hat Service Mesh Operator, add ztunnel to your ServiceMeshControlPlane:

```yaml
apiVersion: maistra.io/v2
kind: ServiceMeshControlPlane
metadata:
  name: basic
  namespace: istio-system
spec:
  version: v2.6  # or appropriate version
  mode: Ambient   # Enable ambient mode
  ambient:
    enabled: true
  components:
    ztunnel:
      enabled: true
    cni:
      enabled: true
```

Apply:
```bash
kubectl apply -f servicemeshcontrolplane.yaml
```

### Option B: Manual Installation with Red Hat Images

If you need to use Red Hat registry images for compliance:

```bash
# You'll need to create a DaemonSet manually using Red Hat images
# Contact Red Hat support for the appropriate ztunnel image
# Or check the Red Hat catalog for available images
```

## Verification Steps

After installation, verify everything is working:

### 1. Check ztunnel Pods

```bash
kubectl get pods -n istio-system -l app=ztunnel -o wide
```

Expected: One pod per node, all Running

### 2. Check CNI Installation

```bash
kubectl get daemonset -n istio-system istio-cni-node
kubectl get pods -n istio-system -l k8s-app=istio-cni-node
```

### 3. Test Waypoint Creation

Now that ztunnel is installed, your existing waypoint gateways should become Programmed:

```bash
# Check gateway status
kubectl get gateway team1-waypoint -n team1

# Should show PROGRAMMED: True (instead of Unknown)
# ADDRESS field should be populated
```

### 4. Check for Waypoint Pods

Once the gateway is Programmed, Istio should create waypoint pods:

```bash
kubectl get pods -n team1 -l gateway.networking.k8s.io/gateway-name=team1-waypoint
```

Expected output:
```
NAME                              READY   STATUS    RESTARTS   AGE
team1-waypoint-abc123-xyz         1/1     Running   0          30s
```

### 5. Verify End-to-End

Re-run the e2e test to confirm waypoints are working:

```bash
# Clean up old resources
kubectl delete namespace team1 team2

# Run test with cleanup disabled to inspect waypoints
export SKIP_CLEANUP=true
./deploy/10-operator-integration-test.sh

# Check waypoint status
kubectl get gateway -n team1
kubectl get pods -n team1 -l gateway.networking.k8s.io/gateway-name
```

## Troubleshooting

### Issue: ztunnel Pods CrashLooping

**Check logs:**
```bash
kubectl logs -n istio-system -l app=ztunnel --tail=50
```

**Common causes:**
- CNI not installed/configured
- Node not compatible with ambient mesh
- Missing required kernel modules

**Solution:**
```bash
# Ensure CNI is installed first
kubectl get daemonset -n istio-system istio-cni-node

# Check node compatibility
kubectl get nodes -o wide
```

### Issue: Gateway Still Shows "Unknown"

**Check events:**
```bash
kubectl describe gateway team1-waypoint -n team1
```

**Check ztunnel connectivity:**
```bash
kubectl exec -n istio-system -l app=ztunnel -- curl localhost:15020/healthz/ready
```

### Issue: Waypoint Pods Not Created

**Check namespace labels:**
```bash
kubectl get ns team1 -o yaml | grep labels -A 5
```

Should have:
```yaml
labels:
  istio.io/dataplane-mode: ambient
```

**Check gateway controller:**
```bash
kubectl logs -n istio-system deployment/istiod | grep -i waypoint
```

## Architecture After ztunnel Installation

```
┌─────────────────────────────────────────────────────────────┐
│ Node                                                         │
│                                                              │
│  ┌─────────────┐          ┌──────────────────────────────┐ │
│  │ ztunnel     │◄─────────│ Istio CNI                    │ │
│  │ (DaemonSet) │          │ (configures iptables/routing)│ │
│  └─────────────┘          └──────────────────────────────┘ │
│        │                                                    │
│        │ Routes L4 traffic to waypoints                    │
│        ▼                                                    │
│  ┌─────────────────────────────────────────────────────┐  │
│  │ team1-waypoint Pod                                  │  │
│  │  - Envoy L7 proxy                                   │  │
│  │  - ext_authz (token exchange)                       │  │
│  │  - AuthorizationPolicy enforcement                  │  │
│  └─────────────────────────────────────────────────────┘  │
│        │                                                    │
│        │ Forwards to destination after token exchange      │
│        ▼                                                    │
│  ┌─────────────┐                                           │
│  │ team2-agent │                                           │
│  │ Pod         │                                           │
│  └─────────────┘                                           │
└─────────────────────────────────────────────────────────────┘
```

## Quick Start (TL;DR)

```bash
# Install Helm repos
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update

# Install CNI
helm install istio-cni istio/cni -n istio-system --version 1.28.4 --set profile=ambient

# Install ztunnel
helm install ztunnel istio/ztunnel -n istio-system --version 1.28.4 --set profile=ambient

# Verify
kubectl get daemonset -n istio-system ztunnel
kubectl get pods -n istio-system -l app=ztunnel

# Test waypoints
kubectl delete ns team1 team2  # Clean old test
export SKIP_CLEANUP=true
./deploy/10-operator-integration-test.sh

# Check waypoint pods
kubectl get gateway -n team1
kubectl get pods -n team1 -l gateway.networking.k8s.io/gateway-name
```

## Next Steps

After ztunnel is installed and working:

1. ✅ Waypoint gateways will become `PROGRAMMED: True`
2. ✅ Waypoint pods will be created automatically
3. ✅ Token exchange at waypoint level will be functional
4. ✅ E2E test will demonstrate complete flow

Your e2e test configuration is already correct - it just needs ztunnel running to create the actual waypoint pods!
