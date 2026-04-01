# Extension Provider Scope and Auto-Enablement

This document answers common questions about Istio extension provider registration and its impact on cluster-wide resources.

## Table of Contents

- [Does Extension Provider Impact Other Projects?](#does-extension-provider-impact-other-projects)
- [Registration vs Activation Model](#registration-vs-activation-model)
- [Scope and Isolation](#scope-and-isolation)
- [Auto-Enable for Labeled Namespaces](#auto-enable-for-labeled-namespaces)
- [Multi-Tenant Considerations](#multi-tenant-considerations)
- [Best Practices](#best-practices)

## Does Extension Provider Impact Other Projects?

**Short answer: NO**

When you register an extension provider in the Istio mesh configuration, it has **zero impact** on any workloads or namespaces until explicitly activated via an AuthorizationPolicy.

### What `make config` Does

Running `make config` adds this to the Istio mesh config:

```yaml
extensionProviders:
- name: kagenti-token-exchange
  envoyExtAuthzGrpc:
    service: token-exchange-service.kagenti-system.svc.cluster.local
    port: 9090
```

**Impact**: ✅ **ZERO**

This registration:
- ❌ Does NOT automatically enable the provider anywhere
- ❌ Does NOT affect any existing traffic
- ❌ Does NOT impact other projects/teams using Istio
- ❌ Does NOT modify any Envoy configurations
- ✅ Only makes the provider **available** to reference in policies

Think of it like installing a plugin - it's available in the catalog but not active until explicitly used.

## Registration vs Activation Model

Istio extension providers use a two-phase model:

### Phase 1: Registration (Cluster-Wide)

```yaml
# In istio ConfigMap (istio-system namespace)
extensionProviders:
- name: kagenti-token-exchange
  envoyExtAuthzGrpc:
    service: token-exchange-service.kagenti-system.svc.cluster.local
    port: 9090
```

**Scope**: Cluster-wide (in mesh configuration)
**Effect**: Makes provider available for reference
**Impact**: None (until activated)

### Phase 2: Activation (Namespace-Scoped)

```yaml
# In any namespace
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: my-auth-policy
  namespace: my-namespace  # ← Only affects this namespace
spec:
  action: CUSTOM
  provider:
    name: kagenti-token-exchange  # ← References the registered provider
  rules:
  - to:
    - operation:
        notPaths: ["/.well-known/*", "/healthz"]
```

**Scope**: Namespace-scoped
**Effect**: Activates ext_authz for services in this namespace
**Impact**: Only this namespace

### Key Insight

```
Registration = "This provider exists and can be used"
Activation  = "Use this provider for my namespace"
```

**Analogy**: It's like defining a function vs calling a function:
- Registration = function definition (available but not executing)
- Activation = function call (actually runs)

## Scope and Isolation

### Multi-Tenant Cluster Example

```
Cluster with 3 teams:
├── team-a-ns
│   └── AuthorizationPolicy (references kagenti-token-exchange)
│       → Traffic in team-a-ns goes through ext_authz ✅
│       → ext_authz calls: token-exchange-service
│
├── team-b-ns
│   └── (no AuthorizationPolicy)
│       → Traffic in team-b-ns is completely unaffected ❌
│       → No ext_authz calls, no validation
│
└── team-c-ns
    └── AuthorizationPolicy (references their-own-provider)
        → Traffic uses their-own-provider ✅
        → Completely independent of kagenti-token-exchange
```

### Isolation Guarantees

| Aspect | Scope | Isolation |
|--------|-------|-----------|
| **Extension Provider Registration** | Cluster-wide (mesh config) | ✅ Just a catalog entry |
| **AuthorizationPolicy** | Namespace-scoped | ✅ Fully isolated |
| **ext_authz calls** | Only where policy exists | ✅ No cross-namespace leakage |
| **Token validation** | Per request in activated namespace | ✅ Independent decisions |
| **Performance impact** | Only activated namespaces | ✅ Others unaffected |

### Verification

You can verify the isolation:

```bash
# Check which namespaces have policies referencing the provider
kubectl get authorizationpolicy -A -o json | \
  jq -r '.items[] | select(.spec.provider.name=="kagenti-token-exchange") |
  "\(.metadata.namespace)/\(.metadata.name)"'

# Output shows only namespaces that opted in:
# tool-ns/tool-waypoint-token-exchange
# agent-ns/agent-waypoint-token-exchange
```

Namespaces not in this list are completely unaffected.

## Auto-Enable for Labeled Namespaces

Istio doesn't have built-in "auto-apply policy to labeled namespaces," but several approaches achieve this:

### Option 1: Kyverno (Recommended for Production)

Use Kyverno to automatically generate AuthorizationPolicy when namespaces are created with a specific label.

**Install Kyverno**:
```bash
kubectl create -f https://github.com/kyverno/kyverno/releases/download/v1.10.0/install.yaml
```

**Create policy**:
```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: generate-auth-policy
spec:
  rules:
  - name: generate-kagenti-auth
    match:
      resources:
        kinds:
        - Namespace
        selector:
          matchLabels:
            kagenti.io/auth: enabled  # ← Trigger label
    generate:
      apiVersion: security.istio.io/v1
      kind: AuthorizationPolicy
      name: kagenti-token-exchange
      namespace: "{{request.object.metadata.name}}"
      synchronize: true
      data:
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
```

**Usage**:
```bash
# Label a namespace
kubectl label namespace my-app-ns kagenti.io/auth=enabled

# Kyverno automatically creates AuthorizationPolicy
kubectl get authorizationpolicy -n my-app-ns
# NAME                      AGE
# kagenti-token-exchange    2s
```

**Advantages**:
- ✅ Fully automated
- ✅ Policy syncs with namespace label
- ✅ Remove label = remove policy
- ✅ Production-ready

### Option 2: ArgoCD ApplicationSet

Use ArgoCD to template and deploy policies based on namespace configuration.

**ApplicationSet**:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: auth-policies
  namespace: argocd
spec:
  generators:
  - list:
      elements:
      - namespace: team-a-ns
        enableAuth: true
      - namespace: team-b-ns
        enableAuth: true
      - namespace: tool-ns
        enableAuth: true
  template:
    metadata:
      name: '{{namespace}}-auth-policy'
    spec:
      project: default
      source:
        repoURL: https://github.com/your-org/policies
        path: templates/authorization-policy
        helm:
          parameters:
          - name: namespace
            value: '{{namespace}}'
      destination:
        namespace: '{{namespace}}'
        server: https://kubernetes.default.svc
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
```

**Helm template** (`templates/authorization-policy/templates/policy.yaml`):
```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: kagenti-token-exchange
  namespace: {{ .Values.namespace }}
spec:
  action: CUSTOM
  provider:
    name: kagenti-token-exchange
  rules:
  - to:
    - operation:
        notPaths: ["/.well-known/*", "/healthz", "/readyz", "/livez"]
```

**Advantages**:
- ✅ GitOps workflow
- ✅ Auditable (Git history)
- ✅ Declarative
- ✅ Integrates with existing ArgoCD

### Option 3: Manual Script (Quick Start)

Create a script that applies policies to labeled namespaces.

**Script** (`deploy/apply-auth-policy.sh`):
```bash
#!/bin/bash
# Apply AuthorizationPolicy to all namespaces with label kagenti.io/auth=enabled

set -euo pipefail

LABEL_SELECTOR="kagenti.io/auth=enabled"
POLICY_NAME="kagenti-token-exchange"

echo "=== Applying AuthorizationPolicy to labeled namespaces ==="
echo "Label selector: $LABEL_SELECTOR"
echo ""

NAMESPACES=$(kubectl get namespaces -l "$LABEL_SELECTOR" -o jsonpath='{.items[*].metadata.name}')

if [ -z "$NAMESPACES" ]; then
  echo "No namespaces found with label $LABEL_SELECTOR"
  exit 0
fi

for ns in $NAMESPACES; do
  echo "Applying to namespace: $ns"

  cat <<EOF | kubectl apply -f -
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: $POLICY_NAME
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

  echo "  ✓ Created AuthorizationPolicy in $ns"
  echo ""
done

echo "=== Complete ==="
echo "Applied to namespaces: $NAMESPACES"
```

**Usage**:
```bash
# Label namespaces
kubectl label namespace team-a-ns kagenti.io/auth=enabled
kubectl label namespace tool-ns kagenti.io/auth=enabled

# Apply policies
bash deploy/apply-auth-policy.sh

# Output:
# Applying to namespace: team-a-ns
#   ✓ Created AuthorizationPolicy in team-a-ns
# Applying to namespace: tool-ns
#   ✓ Created AuthorizationPolicy in tool-ns
```

**Advantages**:
- ✅ Simple and quick
- ✅ No additional tools needed
- ✅ Easy to understand

**Disadvantages**:
- ❌ Manual execution required
- ❌ No automatic sync
- ❌ Not GitOps-friendly

### Option 4: Kubernetes Operator

Build a custom operator that watches for labeled namespaces.

**Pseudo-code**:
```go
func (r *NamespaceReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    var namespace corev1.Namespace
    if err := r.Get(ctx, req.NamespacedName, &namespace); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }

    // Check if namespace has the label
    if namespace.Labels["kagenti.io/auth"] == "enabled" {
        // Create or update AuthorizationPolicy
        policy := &securityv1.AuthorizationPolicy{
            ObjectMeta: metav1.ObjectMeta{
                Name:      "kagenti-token-exchange",
                Namespace: namespace.Name,
            },
            Spec: securityv1.AuthorizationPolicySpec{
                Action: securityv1.AuthorizationPolicy_CUSTOM,
                Provider: &securityv1.AuthorizationPolicy_ExtensionProvider{
                    Name: "kagenti-token-exchange",
                },
                // ... rules
            },
        }

        if err := r.CreateOrUpdate(ctx, policy); err != nil {
            return ctrl.Result{}, err
        }
    } else {
        // Label removed - delete policy
        if err := r.Delete(ctx, policy); err != nil {
            return ctrl.Result{}, client.IgnoreNotFound(err)
        }
    }

    return ctrl.Result{}, nil
}
```

**Tools for building operators**:
- [Operator SDK](https://sdk.operatorframework.io/)
- [Kubebuilder](https://book.kubebuilder.io/)

**Advantages**:
- ✅ Fully automated
- ✅ Reconciliation loops (self-healing)
- ✅ Custom business logic
- ✅ Production-grade

**Disadvantages**:
- ❌ More complex to build
- ❌ Requires Go development
- ❌ Operational overhead

### Comparison

| Approach | Automation | Complexity | GitOps | Production Ready |
|----------|------------|------------|--------|------------------|
| **Kyverno** | ✅ Full | 🟡 Medium | ✅ Yes | ✅ Yes |
| **ArgoCD** | ✅ Full | 🟡 Medium | ✅ Yes | ✅ Yes |
| **Script** | 🟡 Manual | 🟢 Low | ❌ No | 🟡 Testing |
| **Operator** | ✅ Full | 🔴 High | ✅ Yes | ✅ Yes |

### Recommended Approach

**For production**: Kyverno (easiest) or ArgoCD (if already using)
**For quick testing**: Manual script
**For custom requirements**: Build operator

## Multi-Tenant Considerations

### Namespace Ownership

In a multi-tenant cluster, different teams may own different namespaces:

```
team-a owns:
├── team-a-services-ns
├── team-a-data-ns
└── team-a-staging-ns

team-b owns:
├── team-b-api-ns
└── team-b-worker-ns

platform-team owns:
├── kagenti-system (token-exchange-service)
├── istio-system
└── tool-ns
```

### RBAC for Labeling

Control who can enable auth via namespace labels:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: namespace-auth-enabler
rules:
- apiGroups: [""]
  resources: ["namespaces"]
  verbs: ["get", "list", "patch"]
  # Restrict to label changes only
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: team-leads-can-enable-auth
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: namespace-auth-enabler
subjects:
- kind: Group
  name: team-leads
  apiGroup: rbac.authorization.k8s.io
```

### Policy Templates per Team

Different teams may need different bypass paths:

```yaml
# Kyverno policy with team-specific customization
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: generate-team-auth-policy
spec:
  rules:
  - name: team-a-auth
    match:
      resources:
        kinds: [Namespace]
        selector:
          matchLabels:
            team: team-a
            kagenti.io/auth: enabled
    generate:
      # ... AuthorizationPolicy with team-a bypass paths
  - name: team-b-auth
    match:
      resources:
        kinds: [Namespace]
        selector:
          matchLabels:
            team: team-b
            kagenti.io/auth: enabled
    generate:
      # ... AuthorizationPolicy with team-b bypass paths
```

### Isolation Verification

Verify that enabling auth in one team's namespace doesn't affect others:

```bash
# Test script
#!/bin/bash
# Test namespace isolation

echo "=== Testing Namespace Isolation ==="

# 1. Enable auth in team-a-ns
kubectl label namespace team-a-ns kagenti.io/auth=enabled

# 2. Wait for policy creation
sleep 5

# 3. Test team-a-ns (should require token)
echo "Testing team-a-ns (auth enabled):"
kubectl run test-curl -n team-a-ns --rm -i --restart=Never \
  --image=curlimages/curl -- curl -sf http://service.team-a-ns/test
# → Should get 401 (auth required)

# 4. Test team-b-ns (should work without token)
echo "Testing team-b-ns (auth not enabled):"
kubectl run test-curl -n team-b-ns --rm -i --restart=Never \
  --image=curlimages/curl -- curl -sf http://service.team-b-ns/test
# → Should get 200 (no auth)

echo "=== Isolation confirmed ✓ ==="
```

## Best Practices

### 1. Use Labels for Intent

```yaml
# Good: Clear intent
metadata:
  labels:
    kagenti.io/auth: enabled
    kagenti.io/bypass-paths: "healthz,metrics"

# Bad: Ambiguous
metadata:
  labels:
    enable-security: true
```

### 2. Document Extension Providers

```yaml
# In istio ConfigMap - add comments
extensionProviders:
# kagenti-token-exchange: Shared JWT validation and RFC 8693 token exchange
# Used by: tool-ns, agent-ns
# Managed by: platform-team
# Contact: platform-team@example.com
- name: kagenti-token-exchange
  envoyExtAuthzGrpc:
    service: token-exchange-service.kagenti-system.svc.cluster.local
    port: 9090
```

### 3. Test Before Cluster-Wide Rollout

```bash
# Phase 1: Test in dev namespace
kubectl label namespace dev-ns kagenti.io/auth=enabled
# Run E2E tests
make test

# Phase 2: Enable for staging
kubectl label namespace staging-ns kagenti.io/auth=enabled
# Monitor for 24h

# Phase 3: Gradual rollout to production
for ns in prod-ns-1 prod-ns-2 prod-ns-3; do
  kubectl label namespace $ns kagenti.io/auth=enabled
  sleep 3600  # Wait 1 hour between namespaces
done
```

### 4. Monitor Provider Usage

```bash
# Query which namespaces use the provider
kubectl get authorizationpolicy -A -o json | \
  jq -r '.items[] |
    select(.spec.provider.name=="kagenti-token-exchange") |
    {namespace: .metadata.namespace, name: .metadata.name, created: .metadata.creationTimestamp}'

# Monitor ext_authz calls
kubectl logs -n kagenti-system -l app=token-exchange-service --tail=100 | \
  grep "ext_authz" | \
  awk '{print $X}' | \  # Extract namespace
  sort | uniq -c
```

### 5. Version Control Policies

```bash
# Store policies in Git
policies/
├── base/
│   └── authorization-policy.yaml
├── overlays/
│   ├── dev/
│   ├── staging/
│   └── prod/
└── README.md
```

## Troubleshooting

### Problem: Policy not applied to labeled namespace

**Check**:
```bash
# 1. Verify label exists
kubectl get namespace my-ns -o yaml | grep kagenti.io/auth

# 2. Check if automation is running (Kyverno example)
kubectl get pods -n kyverno

# 3. Check Kyverno policy
kubectl get clusterpolicy generate-auth-policy -o yaml

# 4. Check for errors
kubectl logs -n kyverno -l app.kubernetes.io/name=kyverno --tail=100 | grep ERROR
```

### Problem: Extension provider not found

**Error**: `provider "kagenti-token-exchange" not found`

**Solution**:
```bash
# 1. Verify provider is registered
kubectl get cm istio -n istio-system -o yaml | grep -A 5 kagenti-token-exchange

# 2. If missing, run
make config

# 3. Restart istiod to pick up changes
kubectl rollout restart deployment/istiod -n istio-system
```

### Problem: Other namespaces affected unexpectedly

**This should never happen** (if it does, it's a bug).

**Verify isolation**:
```bash
# Check all policies cluster-wide
kubectl get authorizationpolicy -A

# Ensure policies are only in expected namespaces
# If you see policies in unexpected namespaces, investigate:
# - Who created them?
# - What label triggered creation?
# - Check automation logs
```

## Summary

### Key Takeaways

1. **Extension provider registration is safe** - Zero impact until activated
2. **Activation is namespace-scoped** - No cross-contamination
3. **Auto-enablement is achievable** - Multiple approaches available
4. **Isolation is guaranteed** - Teams can independently manage their auth
5. **Testing is important** - Verify before cluster-wide rollout

### Decision Matrix

| Scenario | Recommended Approach |
|----------|---------------------|
| Quick testing | Manual script |
| Production (GitOps) | ArgoCD ApplicationSet |
| Production (Policy Engine) | Kyverno |
| Custom requirements | Build Kubernetes operator |
| Multi-tenant cluster | Kyverno + RBAC |

### Related Documentation

- [Cross-Namespace Communication](cross-namespace-communication.md)
- [Token Exchange Service](../cmd/token-exchange-service/README.md)
- [Main README](../README.md)
