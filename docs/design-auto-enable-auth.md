# Design: Auto-Enable Authorization for Labeled Namespaces

**Status**: Design Proposal
**Author**: Platform Team
**Last Updated**: 2026-04-01

## Problem Statement

The `kagenti-token-exchange` extension provider is registered in the Istio mesh configuration, making it available cluster-wide. However, it only becomes active when an `AuthorizationPolicy` explicitly references it.

**Current workflow** (manual):
```bash
# 1. Create namespace
kubectl create namespace my-app

# 2. Manually create AuthorizationPolicy
kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: kagenti-token-exchange
  namespace: my-app
spec:
  action: CUSTOM
  provider:
    name: kagenti-token-exchange
  rules: [...]
EOF
```

This manual approach doesn't scale for:
- Multi-tenant clusters with many namespaces
- Self-service platforms where teams create namespaces
- Dynamic namespace creation (CI/CD, ephemeral environments)

### Requirements

1. **Opt-in model**: Namespaces must explicitly opt-in via label
2. **Zero impact**: Unlabeled namespaces remain unaffected
3. **Automatic**: No manual policy creation required
4. **Declarative**: Configuration via Kubernetes labels
5. **Auditable**: Track when/why auth was enabled
6. **Reversible**: Removing label disables auth
7. **Customizable**: Different policies for different namespace types

## Impact Analysis: Extension Provider Registration

### Question: Does Extension Provider Impact Other Projects?

**Answer: NO - Zero impact until activated**

#### Understanding the Two-Phase Model

Istio extension providers use a **registration + activation** model:

**Phase 1: Registration** (cluster-wide, done by `make config`)
```yaml
# In istio ConfigMap (istio-system namespace)
extensionProviders:
- name: kagenti-token-exchange
  envoyExtAuthzGrpc:
    service: token-exchange-service.kagenti-system.svc.cluster.local
    port: 9090
```

**Effect**: Makes provider available as a named reference
**Impact**: ❌ **NONE** - Just a catalog entry

**Phase 2: Activation** (namespace-scoped)
```yaml
# In specific namespace
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: my-policy
  namespace: my-namespace  # ← Only affects this namespace
spec:
  action: CUSTOM
  provider:
    name: kagenti-token-exchange  # ← References the registered provider
```

**Effect**: Activates ext_authz for services in this namespace
**Impact**: ✅ **Namespace-scoped only**

#### Isolation Guarantees

```
Multi-tenant cluster:

team-a-ns
  AuthorizationPolicy (references kagenti-token-exchange)
  → ext_authz active ✅
  → Traffic validated and exchanged

team-b-ns
  (no AuthorizationPolicy)
  → ext_authz inactive ❌
  → Traffic flows normally, no validation

team-c-ns
  AuthorizationPolicy (references different-provider)
  → Uses their own provider ✅
  → Completely independent
```

**Key insight**: Registration is like defining a function; activation is like calling it. The function exists globally but has zero effect until explicitly invoked.

#### Verification

```bash
# Check which namespaces have activated the provider
kubectl get authorizationpolicy -A -o json | \
  jq -r '.items[] |
    select(.spec.provider.name=="kagenti-token-exchange") |
    "\(.metadata.namespace)/\(.metadata.name)"'

# Output shows ONLY opted-in namespaces:
# tool-ns/kagenti-token-exchange
# agent-ns/kagenti-token-exchange
# team-a-production/kagenti-token-exchange

# Namespaces NOT in this list are completely unaffected
```

### Conclusion

Extension provider registration in Istio mesh config has **zero operational impact** on existing workloads or other teams. It's a safe, cluster-wide capability that requires explicit opt-in per namespace.

## Proposed Solutions

We evaluated five approaches for auto-enabling authorization:

| Approach | Automation | Complexity | Recommended |
|----------|------------|------------|-------------|
| **Kubernetes Operator** | ✅ Full | 🔴 High | ✅ **Yes** (best for production) |
| **Admission Webhook** | ✅ Full | 🟡 Medium | ✅ **Yes** (good alternative) |
| Kyverno Policy | ✅ Full | 🟡 Medium | No (external dependency) |
| ArgoCD ApplicationSet | ✅ Full | 🟡 Medium | No (requires GitOps) |
| Manual Script | 🟡 Manual | 🟢 Low | No (not scalable) |

**Retained approaches**: Kubernetes Operator and Admission Webhook
**Rationale**:
- No external dependencies (Kyverno, ArgoCD)
- Full control over behavior
- Integrate with existing platform tooling
- Kubernetes-native solutions

## Design: Kubernetes Operator

### Overview

A custom Kubernetes operator that watches `Namespace` resources and automatically creates/updates/deletes `AuthorizationPolicy` resources based on namespace labels.

```
┌─────────────────────────────────────────────────────────┐
│              Kubernetes Operator                        │
│                                                         │
│  ┌──────────────────────────────────────────────┐       │
│  │ Namespace Controller                         │       │
│  │                                              │       │
│  │  Watch: Namespace resources                 │       │
│  │  Trigger: Label changes                      │       │
│  │  Action: Reconcile AuthorizationPolicy       │       │
│  └──────────────────────────────────────────────┘       │
└─────────────────────────────────────────────────────────┘
                        │
        ┌───────────────┼───────────────┐
        │               │               │
        ▼               ▼               ▼
  ┌──────────┐    ┌──────────┐    ┌──────────┐
  │Namespace │    │Namespace │    │Namespace │
  │ team-a   │    │ team-b   │    │ team-c   │
  │ label:✓  │    │ label:✗  │    │ label:✓  │
  └────┬─────┘    └──────────┘    └────┬─────┘
       │                                │
       ▼                                ▼
  ┌──────────────┐              ┌──────────────┐
  │AuthPolicy    │              │AuthPolicy    │
  │(created)     │              │(created)     │
  └──────────────┘              └──────────────┘
```

### Architecture

#### Components

```
kagenti-auth-operator/
├── cmd/
│   └── operator/
│       └── main.go              # Operator entrypoint
├── pkg/
│   ├── controller/
│   │   └── namespace_controller.go  # Reconciliation logic
│   ├── templates/
│   │   └── authpolicy.go        # Policy templates
│   └── config/
│       └── config.go            # Operator configuration
├── config/
│   ├── crd/                     # Custom Resource Definitions (if needed)
│   ├── rbac/                    # RBAC for operator
│   └── manager/                 # Operator deployment
└── Dockerfile
```

#### Reconciliation Logic

```go
package controller

import (
    "context"
    corev1 "k8s.io/api/core/v1"
    securityv1 "istio.io/client-go/pkg/apis/security/v1"
    "sigs.k8s.io/controller-runtime/pkg/client"
    "sigs.k8s.io/controller-runtime/pkg/reconcile"
)

const (
    // Label that triggers auth enablement
    AuthEnabledLabel = "kagenti.io/auth"
    // Value that enables auth
    AuthEnabledValue = "enabled"
    // Policy name (consistent across namespaces)
    PolicyName = "kagenti-token-exchange"
)

type NamespaceReconciler struct {
    client.Client
    Config OperatorConfig
}

// Reconcile handles namespace changes
func (r *NamespaceReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
    log := logr.FromContext(ctx)

    // 1. Fetch the namespace
    var namespace corev1.Namespace
    if err := r.Get(ctx, req.NamespacedName, &namespace); err != nil {
        return reconcile.Result{}, client.IgnoreNotFound(err)
    }

    // 2. Check if namespace is being deleted
    if !namespace.DeletionTimestamp.IsZero() {
        log.Info("namespace is being deleted, skipping reconciliation")
        return reconcile.Result{}, nil
    }

    // 3. Determine desired state based on label
    authEnabled := namespace.Labels[AuthEnabledLabel] == AuthEnabledValue

    // 4. Get current AuthorizationPolicy (if exists)
    currentPolicy := &securityv1.AuthorizationPolicy{}
    policyKey := client.ObjectKey{
        Namespace: namespace.Name,
        Name:      PolicyName,
    }
    err := r.Get(ctx, policyKey, currentPolicy)
    policyExists := err == nil

    // 5. Reconcile based on desired vs current state
    if authEnabled && !policyExists {
        // Create policy
        return r.createAuthPolicy(ctx, &namespace)
    } else if authEnabled && policyExists {
        // Update policy if needed
        return r.updateAuthPolicy(ctx, &namespace, currentPolicy)
    } else if !authEnabled && policyExists {
        // Delete policy
        return r.deleteAuthPolicy(ctx, currentPolicy)
    }

    // No action needed
    return reconcile.Result{}, nil
}

// createAuthPolicy creates an AuthorizationPolicy in the namespace
func (r *NamespaceReconciler) createAuthPolicy(ctx context.Context, ns *corev1.Namespace) (reconcile.Result, error) {
    log := logr.FromContext(ctx)

    // Generate policy from template
    policy := r.buildAuthPolicy(ns)

    // Set owner reference (optional, for garbage collection)
    // Note: Cross-namespace owner references are not allowed in Kubernetes,
    // so we use finalizers instead

    if err := r.Create(ctx, policy); err != nil {
        log.Error(err, "failed to create AuthorizationPolicy")
        return reconcile.Result{}, err
    }

    log.Info("created AuthorizationPolicy",
        "namespace", ns.Name,
        "policy", PolicyName)

    // Record event
    r.EventRecorder.Event(ns, corev1.EventTypeNormal, "AuthEnabled",
        "Created AuthorizationPolicy for token exchange")

    return reconcile.Result{}, nil
}

// updateAuthPolicy updates an existing AuthorizationPolicy
func (r *NamespaceReconciler) updateAuthPolicy(ctx context.Context, ns *corev1.Namespace, current *securityv1.AuthorizationPolicy) (reconcile.Result, error) {
    log := logr.FromContext(ctx)

    // Generate desired policy
    desired := r.buildAuthPolicy(ns)

    // Compare and update if different
    if !reflect.DeepEqual(current.Spec, desired.Spec) {
        current.Spec = desired.Spec

        if err := r.Update(ctx, current); err != nil {
            log.Error(err, "failed to update AuthorizationPolicy")
            return reconcile.Result{}, err
        }

        log.Info("updated AuthorizationPolicy",
            "namespace", ns.Name,
            "policy", PolicyName)
    }

    return reconcile.Result{}, nil
}

// deleteAuthPolicy removes an AuthorizationPolicy
func (r *NamespaceReconciler) deleteAuthPolicy(ctx context.Context, policy *securityv1.AuthorizationPolicy) (reconcile.Result, error) {
    log := logr.FromContext(ctx)

    if err := r.Delete(ctx, policy); err != nil {
        log.Error(err, "failed to delete AuthorizationPolicy")
        return reconcile.Result{}, err
    }

    log.Info("deleted AuthorizationPolicy",
        "namespace", policy.Namespace,
        "policy", PolicyName)

    return reconcile.Result{}, nil
}

// buildAuthPolicy constructs the AuthorizationPolicy resource
func (r *NamespaceReconciler) buildAuthPolicy(ns *corev1.Namespace) *securityv1.AuthorizationPolicy {
    // Check for custom bypass paths in namespace annotations
    bypassPaths := r.getBypassPaths(ns)

    policy := &securityv1.AuthorizationPolicy{
        ObjectMeta: metav1.ObjectMeta{
            Name:      PolicyName,
            Namespace: ns.Name,
            Labels: map[string]string{
                "app.kubernetes.io/managed-by": "kagenti-auth-operator",
                "kagenti.io/auth":              "true",
            },
            Annotations: map[string]string{
                "kagenti.io/created-by":    "kagenti-auth-operator",
                "kagenti.io/created-from":  ns.Name,
                "kagenti.io/trigger-label": AuthEnabledLabel,
            },
        },
        Spec: securityv1.AuthorizationPolicySpec{
            Action: securityv1.AuthorizationPolicy_CUSTOM,
            Provider: &securityv1.AuthorizationPolicy_ExtensionProvider{
                Name: "kagenti-token-exchange",
            },
            Rules: []*securityv1.Rule{
                {
                    To: []*securityv1.Rule_To{
                        {
                            Operation: &securityv1.Operation{
                                NotPaths: bypassPaths,
                            },
                        },
                    },
                },
            },
        },
    }

    return policy
}

// getBypassPaths extracts bypass paths from namespace annotations
func (r *NamespaceReconciler) getBypassPaths(ns *corev1.Namespace) []string {
    // Check for custom bypass paths in annotations
    if customPaths, ok := ns.Annotations["kagenti.io/bypass-paths"]; ok {
        return strings.Split(customPaths, ",")
    }

    // Default bypass paths
    return []string{
        "/.well-known/*",
        "/healthz",
        "/readyz",
        "/livez",
    }
}
```

#### Operator Configuration

```go
// pkg/config/config.go
package config

type OperatorConfig struct {
    // Namespace where operator runs
    OperatorNamespace string

    // Extension provider name
    ProviderName string

    // Default bypass paths
    DefaultBypassPaths []string

    // Label selector
    TriggerLabel string
    TriggerValue string

    // Reconciliation settings
    EnableLeaderElection bool
    MetricsAddr          string
    ProbeAddr            string
}

func LoadConfig() (*OperatorConfig, error) {
    return &OperatorConfig{
        OperatorNamespace:    getEnv("OPERATOR_NAMESPACE", "kagenti-system"),
        ProviderName:         getEnv("PROVIDER_NAME", "kagenti-token-exchange"),
        DefaultBypassPaths:   strings.Split(getEnv("DEFAULT_BYPASS_PATHS", "/.well-known/*,/healthz,/readyz,/livez"), ","),
        TriggerLabel:         getEnv("TRIGGER_LABEL", "kagenti.io/auth"),
        TriggerValue:         getEnv("TRIGGER_VALUE", "enabled"),
        EnableLeaderElection: getEnvBool("ENABLE_LEADER_ELECTION", true),
        MetricsAddr:          getEnv("METRICS_ADDR", ":8080"),
        ProbeAddr:            getEnv("PROBE_ADDR", ":8081"),
    }, nil
}
```

#### Main Entrypoint

```go
// cmd/operator/main.go
package main

import (
    "flag"
    "os"

    corev1 "k8s.io/api/core/v1"
    "k8s.io/apimachinery/pkg/runtime"
    clientgoscheme "k8s.io/client-go/kubernetes/scheme"
    ctrl "sigs.k8s.io/controller-runtime"
    "sigs.k8s.io/controller-runtime/pkg/healthz"
    "sigs.k8s.io/controller-runtime/pkg/log/zap"

    securityv1 "istio.io/client-go/pkg/apis/security/v1"
    "github.com/kagenti/authbridge-waypoint/pkg/controller"
    "github.com/kagenti/authbridge-waypoint/pkg/config"
)

var (
    scheme   = runtime.NewScheme()
    setupLog = ctrl.Log.WithName("setup")
)

func init() {
    _ = clientgoscheme.AddToScheme(scheme)
    _ = corev1.AddToScheme(scheme)
    _ = securityv1.AddToScheme(scheme)
}

func main() {
    var metricsAddr string
    var enableLeaderElection bool
    var probeAddr string

    flag.StringVar(&metricsAddr, "metrics-bind-address", ":8080", "The address the metric endpoint binds to.")
    flag.StringVar(&probeAddr, "health-probe-bind-address", ":8081", "The address the probe endpoint binds to.")
    flag.BoolVar(&enableLeaderElection, "leader-elect", false, "Enable leader election for controller manager.")
    flag.Parse()

    ctrl.SetLogger(zap.New(zap.UseDevMode(true)))

    // Load configuration
    cfg, err := config.LoadConfig()
    if err != nil {
        setupLog.Error(err, "unable to load config")
        os.Exit(1)
    }

    // Create manager
    mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
        Scheme:                 scheme,
        MetricsBindAddress:     metricsAddr,
        Port:                   9443,
        HealthProbeBindAddress: probeAddr,
        LeaderElection:         enableLeaderElection,
        LeaderElectionID:       "kagenti-auth-operator-leader",
    })
    if err != nil {
        setupLog.Error(err, "unable to start manager")
        os.Exit(1)
    }

    // Setup controller
    if err = (&controller.NamespaceReconciler{
        Client: mgr.GetClient(),
        Config: *cfg,
    }).SetupWithManager(mgr); err != nil {
        setupLog.Error(err, "unable to create controller", "controller", "Namespace")
        os.Exit(1)
    }

    // Health checks
    if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
        setupLog.Error(err, "unable to set up health check")
        os.Exit(1)
    }
    if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
        setupLog.Error(err, "unable to set up ready check")
        os.Exit(1)
    }

    setupLog.Info("starting manager")
    if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
        setupLog.Error(err, "problem running manager")
        os.Exit(1)
    }
}
```

### Deployment

#### RBAC

```yaml
# config/rbac/role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kagenti-auth-operator
rules:
# Watch namespaces
- apiGroups: [""]
  resources: ["namespaces"]
  verbs: ["get", "list", "watch"]
# Manage AuthorizationPolicies
- apiGroups: ["security.istio.io"]
  resources: ["authorizationpolicies"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
# Events (for auditing)
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kagenti-auth-operator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kagenti-auth-operator
subjects:
- kind: ServiceAccount
  name: kagenti-auth-operator
  namespace: kagenti-system
```

#### Deployment Manifest

```yaml
# config/manager/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kagenti-auth-operator
  namespace: kagenti-system
  labels:
    app: kagenti-auth-operator
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kagenti-auth-operator
  template:
    metadata:
      labels:
        app: kagenti-auth-operator
    spec:
      serviceAccountName: kagenti-auth-operator
      containers:
      - name: manager
        image: localhost:5000/kagenti-auth-operator:latest
        command:
        - /manager
        args:
        - --leader-elect
        - --metrics-bind-address=:8080
        - --health-probe-bind-address=:8081
        env:
        - name: OPERATOR_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: PROVIDER_NAME
          value: "kagenti-token-exchange"
        - name: TRIGGER_LABEL
          value: "kagenti.io/auth"
        - name: TRIGGER_VALUE
          value: "enabled"
        - name: DEFAULT_BYPASS_PATHS
          value: "/.well-known/*,/healthz,/readyz,/livez"
        ports:
        - containerPort: 8080
          name: metrics
          protocol: TCP
        - containerPort: 8081
          name: health
          protocol: TCP
        livenessProbe:
          httpGet:
            path: /healthz
            port: health
          initialDelaySeconds: 15
          periodSeconds: 20
        readinessProbe:
          httpGet:
            path: /readyz
            port: health
          initialDelaySeconds: 5
          periodSeconds: 10
        resources:
          limits:
            cpu: 200m
            memory: 128Mi
          requests:
            cpu: 100m
            memory: 64Mi
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
          runAsNonRoot: true
          seccompProfile:
            type: RuntimeDefault
```

### Usage

```bash
# 1. Deploy operator
kubectl apply -f config/rbac/
kubectl apply -f config/manager/

# 2. Label a namespace to enable auth
kubectl label namespace my-app kagenti.io/auth=enabled

# 3. Operator automatically creates AuthorizationPolicy
kubectl get authorizationpolicy -n my-app
# NAME                      AGE
# kagenti-token-exchange    5s

# 4. Verify policy
kubectl get authorizationpolicy kagenti-token-exchange -n my-app -o yaml

# 5. To disable auth, remove label
kubectl label namespace my-app kagenti.io/auth-

# 6. Operator automatically deletes AuthorizationPolicy
```

### Advanced Features

#### Custom Bypass Paths per Namespace

```bash
# Set custom bypass paths via annotation
kubectl annotate namespace my-app \
  kagenti.io/bypass-paths="/.well-known/*,/healthz,/public/*,/metrics"

# Operator will use these paths in the AuthorizationPolicy
```

#### Policy Templates per Namespace Type

```go
// Support different policy templates
func (r *NamespaceReconciler) buildAuthPolicy(ns *corev1.Namespace) *securityv1.AuthorizationPolicy {
    // Check namespace type annotation
    nsType := ns.Annotations["kagenti.io/namespace-type"]

    switch nsType {
    case "production":
        return r.buildProductionPolicy(ns)
    case "staging":
        return r.buildStagingPolicy(ns)
    default:
        return r.buildDefaultPolicy(ns)
    }
}
```

### Advantages

- ✅ **Kubernetes-native**: Uses controller-runtime pattern
- ✅ **Declarative**: Configuration via labels/annotations
- ✅ **Automatic reconciliation**: Self-healing
- ✅ **Leader election**: High availability (multiple replicas)
- ✅ **Events and logging**: Full audit trail
- ✅ **Customizable**: Templates, bypass paths, namespace types
- ✅ **Production-ready**: Health checks, metrics, RBAC

### Disadvantages

- ❌ **Development complexity**: Requires Go development
- ❌ **Operational overhead**: Another component to maintain
- ❌ **Learning curve**: Understanding controller-runtime

---

## Design: Admission Webhook

### Overview

A Kubernetes admission webhook (mutating or validating) that intercepts namespace creation/update events and automatically injects or validates `AuthorizationPolicy` resources.

```
┌─────────────────────────────────────────────────────────┐
│          Kubernetes API Server                          │
│                                                         │
│  ┌────────────────────────────────────┐                 │
│  │ Admission Controller Chain         │                 │
│  │                                    │                 │
│  │  1. NamespaceLifecycle             │                 │
│  │  2. LimitRanger                    │                 │
│  │  3. ServiceAccount                 │                 │
│  │  4. ────────────────────────────┐  │                 │
│  │       MutatingWebhook           │  │                 │
│  │       (kagenti-auth-injector) ──┼──┼─────────┐       │
│  │                                 │  │         │       │
│  │  5. ValidatingWebhook           │  │         │       │
│  └────────────────────────────────────┘         │       │
└─────────────────────────────────────────────────┼───────┘
                                                  │
                                                  ▼
                                    ┌──────────────────────┐
                                    │ Webhook Server       │
                                    │ (kagenti-system)     │
                                    │                      │
                                    │ POST /mutate         │
                                    │  - Check namespace   │
                                    │  - Generate policy   │
                                    │  - Return patch      │
                                    └──────────────────────┘
```

### Architecture

#### Webhook Types

**Option A: Mutating Webhook** (Recommended)
- Intercepts namespace creation
- Generates and injects AuthorizationPolicy as a side effect
- Policy created atomically with namespace

**Option B: Validating Webhook**
- Validates that labeled namespaces have policies
- Rejects namespace creation if policy missing
- Requires external process to create policy

**Choice**: Mutating webhook (more user-friendly, automatic)

#### Implementation

```go
// cmd/webhook/main.go
package main

import (
    "encoding/json"
    "fmt"
    "io"
    "net/http"

    admissionv1 "k8s.io/api/admission/v1"
    corev1 "k8s.io/api/core/v1"
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
    securityv1 "istio.io/client-go/pkg/apis/security/v1"
)

const (
    AuthEnabledLabel = "kagenti.io/auth"
    AuthEnabledValue = "enabled"
)

type WebhookServer struct {
    Client kubernetes.Interface
}

func (ws *WebhookServer) handleMutate(w http.ResponseWriter, r *http.Request) {
    // 1. Read admission review request
    body, err := io.ReadAll(r.Body)
    if err != nil {
        http.Error(w, "failed to read request", http.StatusBadRequest)
        return
    }

    admissionReview := admissionv1.AdmissionReview{}
    if err := json.Unmarshal(body, &admissionReview); err != nil {
        http.Error(w, "failed to unmarshal request", http.StatusBadRequest)
        return
    }

    // 2. Extract namespace from request
    req := admissionReview.Request
    namespace := corev1.Namespace{}
    if err := json.Unmarshal(req.Object.Raw, &namespace); err != nil {
        ws.denyAdmission(w, req.UID, "failed to unmarshal namespace")
        return
    }

    // 3. Check if auth should be enabled
    authEnabled := namespace.Labels[AuthEnabledLabel] == AuthEnabledValue

    if !authEnabled {
        // No action needed
        ws.allowAdmission(w, req.UID, nil)
        return
    }

    // 4. Generate AuthorizationPolicy
    policy := ws.buildAuthPolicy(&namespace)

    // 5. Create policy in the namespace (async, after webhook returns)
    go func() {
        // Wait for namespace to be created
        time.Sleep(2 * time.Second)

        // Create policy
        _, err := ws.Client.SecurityV1().AuthorizationPolicies(namespace.Name).
            Create(context.Background(), policy, metav1.CreateOptions{})
        if err != nil {
            log.Printf("failed to create policy in %s: %v", namespace.Name, err)
        } else {
            log.Printf("created AuthorizationPolicy in namespace %s", namespace.Name)
        }
    }()

    // 6. Allow the namespace creation
    ws.allowAdmission(w, req.UID, nil)
}

func (ws *WebhookServer) buildAuthPolicy(ns *corev1.Namespace) *securityv1.AuthorizationPolicy {
    bypassPaths := []string{"/.well-known/*", "/healthz", "/readyz", "/livez"}

    // Check for custom bypass paths
    if custom, ok := ns.Annotations["kagenti.io/bypass-paths"]; ok {
        bypassPaths = strings.Split(custom, ",")
    }

    return &securityv1.AuthorizationPolicy{
        ObjectMeta: metav1.ObjectMeta{
            Name:      "kagenti-token-exchange",
            Namespace: ns.Name,
            Labels: map[string]string{
                "app.kubernetes.io/managed-by": "kagenti-auth-webhook",
            },
        },
        Spec: securityv1.AuthorizationPolicySpec{
            Action: securityv1.AuthorizationPolicy_CUSTOM,
            Provider: &securityv1.AuthorizationPolicy_ExtensionProvider{
                Name: "kagenti-token-exchange",
            },
            Rules: []*securityv1.Rule{
                {
                    To: []*securityv1.Rule_To{
                        {
                            Operation: &securityv1.Operation{
                                NotPaths: bypassPaths,
                            },
                        },
                    },
                },
            },
        },
    }
}

func (ws *WebhookServer) allowAdmission(w http.ResponseWriter, uid types.UID, patches []map[string]interface{}) {
    response := admissionv1.AdmissionReview{
        TypeMeta: metav1.TypeMeta{
            APIVersion: "admission.k8s.io/v1",
            Kind:       "AdmissionReview",
        },
        Response: &admissionv1.AdmissionResponse{
            UID:     uid,
            Allowed: true,
        },
    }

    // Add patches if provided
    if patches != nil {
        patchBytes, _ := json.Marshal(patches)
        response.Response.Patch = patchBytes
        response.Response.PatchType = func() *admissionv1.PatchType {
            pt := admissionv1.PatchTypeJSONPatch
            return &pt
        }()
    }

    ws.writeResponse(w, response)
}

func (ws *WebhookServer) denyAdmission(w http.ResponseWriter, uid types.UID, message string) {
    response := admissionv1.AdmissionReview{
        TypeMeta: metav1.TypeMeta{
            APIVersion: "admission.k8s.io/v1",
            Kind:       "AdmissionReview",
        },
        Response: &admissionv1.AdmissionResponse{
            UID:     uid,
            Allowed: false,
            Result: &metav1.Status{
                Message: message,
            },
        },
    }

    ws.writeResponse(w, response)
}

func (ws *WebhookServer) writeResponse(w http.ResponseWriter, response admissionv1.AdmissionReview) {
    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(response)
}

func main() {
    // Setup Kubernetes client
    config, err := rest.InClusterConfig()
    if err != nil {
        log.Fatal(err)
    }

    client, err := kubernetes.NewForConfig(config)
    if err != nil {
        log.Fatal(err)
    }

    ws := &WebhookServer{Client: client}

    // Setup HTTPS server
    http.HandleFunc("/mutate", ws.handleMutate)
    http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
        w.WriteHeader(http.StatusOK)
    })

    // Load TLS certificates (required for admission webhooks)
    certFile := "/etc/webhook/certs/tls.crt"
    keyFile := "/etc/webhook/certs/tls.key"

    log.Println("Starting webhook server on :8443")
    if err := http.ListenAndServeTLS(":8443", certFile, keyFile, nil); err != nil {
        log.Fatal(err)
    }
}
```

### Deployment

#### Webhook Configuration

```yaml
# config/webhook/mutating-webhook.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: kagenti-auth-webhook
webhooks:
- name: auth.kagenti.io
  clientConfig:
    service:
      name: kagenti-auth-webhook
      namespace: kagenti-system
      path: /mutate
    caBundle: ${CA_BUNDLE}  # Base64-encoded CA certificate
  rules:
  - apiGroups: [""]
    apiVersions: ["v1"]
    operations: ["CREATE", "UPDATE"]
    resources: ["namespaces"]
    scope: "*"
  namespaceSelector:
    matchLabels:
      kagenti.io/auth: enabled
  admissionReviewVersions: ["v1"]
  sideEffects: None
  timeoutSeconds: 10
  failurePolicy: Ignore  # Don't block namespace creation if webhook fails
```

#### Service and Deployment

```yaml
# config/webhook/deployment.yaml
apiVersion: v1
kind: Service
metadata:
  name: kagenti-auth-webhook
  namespace: kagenti-system
spec:
  selector:
    app: kagenti-auth-webhook
  ports:
  - port: 443
    targetPort: 8443
    protocol: TCP
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kagenti-auth-webhook
  namespace: kagenti-system
spec:
  replicas: 2  # For high availability
  selector:
    matchLabels:
      app: kagenti-auth-webhook
  template:
    metadata:
      labels:
        app: kagenti-auth-webhook
    spec:
      serviceAccountName: kagenti-auth-webhook
      containers:
      - name: webhook
        image: localhost:5000/kagenti-auth-webhook:latest
        ports:
        - containerPort: 8443
          name: https
        volumeMounts:
        - name: certs
          mountPath: /etc/webhook/certs
          readOnly: true
        env:
        - name: PROVIDER_NAME
          value: "kagenti-token-exchange"
        livenessProbe:
          httpGet:
            scheme: HTTPS
            path: /healthz
            port: 8443
        resources:
          limits:
            cpu: 100m
            memory: 64Mi
          requests:
            cpu: 50m
            memory: 32Mi
      volumes:
      - name: certs
        secret:
          secretName: kagenti-auth-webhook-certs
```

#### Certificate Generation

Admission webhooks require TLS. Use cert-manager or generate manually:

```bash
# Using cert-manager
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: kagenti-auth-webhook
  namespace: kagenti-system
spec:
  secretName: kagenti-auth-webhook-certs
  issuerRef:
    name: selfsigned-issuer
    kind: Issuer
  dnsNames:
  - kagenti-auth-webhook.kagenti-system.svc
  - kagenti-auth-webhook.kagenti-system.svc.cluster.local
EOF
```

### Usage

```bash
# 1. Deploy webhook
kubectl apply -f config/webhook/

# 2. Create namespace with label
kubectl create namespace my-app
kubectl label namespace my-app kagenti.io/auth=enabled

# 3. Webhook intercepts creation and creates policy
# (Policy created automatically within ~2 seconds)

# 4. Verify
kubectl get authorizationpolicy -n my-app
```

### Advantages

- ✅ **Lightweight**: Simpler than operator
- ✅ **Immediate**: Triggers on namespace creation
- ✅ **No polling**: Event-driven
- ✅ **Kubernetes-native**: Standard admission controller pattern
- ✅ **Less code**: No reconciliation loops

### Disadvantages

- ❌ **No reconciliation**: Doesn't heal if policy deleted
- ❌ **Async creation**: Policy created after namespace (small delay)
- ❌ **Certificate management**: Requires TLS setup
- ❌ **Failure handling**: Need to handle webhook downtime

---

## Comparison: Operator vs Webhook

| Aspect | Kubernetes Operator | Admission Webhook |
|--------|-------------------|-------------------|
| **Complexity** | 🔴 High (controller-runtime) | 🟡 Medium (webhook server) |
| **Reconciliation** | ✅ Yes (self-healing) | ❌ No (one-time) |
| **Dependencies** | controller-runtime | TLS certificates |
| **Code size** | ~500-800 LOC | ~300-400 LOC |
| **High availability** | ✅ Leader election | ✅ Multiple replicas |
| **Failure mode** | Retries until success | Fails silently (if failurePolicy: Ignore) |
| **Customization** | ✅ Full control | ✅ Full control |
| **Maintenance** | 🔴 Higher | 🟡 Medium |
| **Production ready** | ✅ Yes | ✅ Yes |

## Recommendation

**For production deployment**: **Kubernetes Operator**

**Rationale**:
1. **Self-healing**: Reconciliation ensures policies stay synchronized with namespace labels
2. **Robust**: Handles edge cases (policy deleted, label changed)
3. **Auditable**: Full event logging and status tracking
4. **Scalable**: Proven pattern for managing cluster-wide resources
5. **Battle-tested**: controller-runtime is production-grade

**Webhook is suitable when**:
- Simpler deployment preferred
- No need for reconciliation
- cert-manager already in use

## Implementation Plan

### Phase 1: Development (Week 1-2)
- [ ] Implement operator using Kubebuilder/Operator SDK
- [ ] Write unit tests
- [ ] Local testing with Kind cluster
- [ ] Documentation

### Phase 2: Integration Testing (Week 3)
- [ ] Deploy to staging cluster
- [ ] Test label add/remove
- [ ] Test policy customization
- [ ] Performance testing

### Phase 3: Production Rollout (Week 4)
- [ ] Deploy to production (kagenti-system namespace)
- [ ] Enable for pilot namespaces
- [ ] Monitor metrics and logs
- [ ] Gradual rollout to all namespaces

## Security Considerations

1. **RBAC**: Operator needs cluster-wide permissions
   - Minimize permissions (only namespaces + authorizationpolicies)
   - Use separate ServiceAccount
   - Audit RBAC regularly

2. **Label tampering**: Prevent unauthorized label changes
   - RBAC restrictions on namespace label modifications
   - ValidatingWebhook to enforce label policies

3. **Policy override**: Prevent policy deletion
   - Operator recreates deleted policies
   - Alert on manual policy modifications

4. **Audit trail**: Track all changes
   - Kubernetes events for policy creation/deletion
   - Structured logging for reconciliation
   - Metrics for monitoring

## Monitoring and Observability

### Metrics (Prometheus)

```
# Operator metrics
kagenti_auth_operator_reconcile_total{namespace, result}
kagenti_auth_operator_reconcile_duration_seconds{namespace}
kagenti_auth_operator_policies_managed{namespace}

# Webhook metrics
kagenti_auth_webhook_requests_total{operation, result}
kagenti_auth_webhook_request_duration_seconds{operation}
```

### Alerts

```yaml
# Alert if operator stops reconciling
- alert: AuthOperatorDown
  expr: up{job="kagenti-auth-operator"} == 0
  for: 5m

# Alert if webhook fails frequently
- alert: AuthWebhookFailures
  expr: rate(kagenti_auth_webhook_requests_total{result="error"}[5m]) > 0.1
  for: 5m
```

### Logging

Structured logs for all operations:
```json
{
  "level": "info",
  "timestamp": "2026-04-01T10:30:00Z",
  "msg": "created AuthorizationPolicy",
  "namespace": "team-a-production",
  "policy": "kagenti-token-exchange",
  "trigger_label": "kagenti.io/auth=enabled"
}
```

## Conclusion

Both operator and webhook approaches are viable for auto-enabling authorization in labeled namespaces. The **Kubernetes Operator** is recommended for production due to its self-healing capabilities and robust reconciliation model. The solution has zero impact on unlabeled namespaces, maintaining full isolation in multi-tenant clusters.

## References

- [Kubernetes Operators](https://kubernetes.io/docs/concepts/extend-kubernetes/operator/)
- [Admission Webhooks](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/)
- [controller-runtime](https://github.com/kubernetes-sigs/controller-runtime)
- [Kubebuilder Book](https://book.kubebuilder.io/)
- [Istio AuthorizationPolicy](https://istio.io/latest/docs/reference/config/security/authorization-policy/)
