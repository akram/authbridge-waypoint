#!/usr/bin/env bash
# Configure Istio mesh with kagenti-token-exchange ext_authz provider.
#
# This script patches the istio ConfigMap in istio-system to add the
# extensionProviders entry needed for waypoint-based token exchange.
#
# Usage: bash deploy/02-configure-istio.sh
set -euo pipefail

ISTIO_NS="${ISTIO_NS:-istio-system}"
CONFIGMAP_NAME="${ISTIO_CONFIGMAP:-istio}"
PROVIDER_NAME="kagenti-token-exchange"
SERVICE_NAME="token-exchange-service.kagenti-system.svc.cluster.local"
SERVICE_PORT="9090"

echo "=== Configuring Istio mesh for authbridge-waypoint ==="
echo "  Namespace: $ISTIO_NS"
echo "  ConfigMap: $CONFIGMAP_NAME"

# Check if Istio is installed
if ! kubectl get ns "$ISTIO_NS" >/dev/null 2>&1; then
  echo "ERROR: Istio namespace '$ISTIO_NS' not found."
  echo "Please install Istio first."
  exit 1
fi

if ! kubectl get cm "$CONFIGMAP_NAME" -n "$ISTIO_NS" >/dev/null 2>&1; then
  echo "ERROR: Istio ConfigMap '$CONFIGMAP_NAME' not found in namespace '$ISTIO_NS'."
  echo "Is Istio properly installed?"
  exit 1
fi

# Check if the provider already exists
CURRENT_CONFIG=$(kubectl get cm "$CONFIGMAP_NAME" -n "$ISTIO_NS" -o jsonpath='{.data.mesh}')
if echo "$CURRENT_CONFIG" | grep -q "$PROVIDER_NAME"; then
  echo "✓ Extension provider '$PROVIDER_NAME' already configured"
  exit 0
fi

echo "Adding extension provider '$PROVIDER_NAME'..."

# Create a temporary file with the patch
TEMP_PATCH=$(mktemp)
trap "rm -f $TEMP_PATCH" EXIT

cat > "$TEMP_PATCH" <<EOF
data:
  mesh: |
$(kubectl get cm "$CONFIGMAP_NAME" -n "$ISTIO_NS" -o jsonpath='{.data.mesh}' | sed 's/^/    /')
    extensionProviders:
    - name: $PROVIDER_NAME
      envoyExtAuthzGrpc:
        service: $SERVICE_NAME
        port: $SERVICE_PORT
EOF

# Check if extensionProviders section already exists (but without our provider)
if echo "$CURRENT_CONFIG" | grep -q "extensionProviders:"; then
  echo "  Existing extensionProviders section found, appending to it..."

  # More complex patch - need to append to existing extensionProviders
  kubectl get cm "$CONFIGMAP_NAME" -n "$ISTIO_NS" -o yaml > "${TEMP_PATCH}.yaml"

  # Use yq or manual sed to add the provider
  if command -v yq >/dev/null 2>&1; then
    yq eval ".data.mesh |= (. | sub(\"extensionProviders:\", \"extensionProviders:\n    - name: $PROVIDER_NAME\n      envoyExtAuthzGrpc:\n        service: $SERVICE_NAME\n        port: $SERVICE_PORT\"))" -i "${TEMP_PATCH}.yaml"
    kubectl apply -f "${TEMP_PATCH}.yaml"
  else
    # Fallback: use kubectl patch with strategic merge
    cat > "$TEMP_PATCH" <<'PATCH_EOF'
data:
  mesh: |-
PATCH_EOF

    # Get current mesh config and add our provider
    kubectl get cm "$CONFIGMAP_NAME" -n "$ISTIO_NS" -o jsonpath='{.data.mesh}' | \
      awk -v provider="$PROVIDER_NAME" -v svc="$SERVICE_NAME" -v port="$SERVICE_PORT" '
        /extensionProviders:/ {
          print $0
          print "    - name: " provider
          print "      envoyExtAuthzGrpc:"
          print "        service: " svc
          print "        port: " port
          next
        }
        { print }
      ' | sed 's/^/    /' >> "$TEMP_PATCH"

    kubectl patch cm "$CONFIGMAP_NAME" -n "$ISTIO_NS" --patch-file "$TEMP_PATCH"
  fi
else
  # No extensionProviders section exists, use simple patch
  echo "  No existing extensionProviders section, creating new one..."
  kubectl patch cm "$CONFIGMAP_NAME" -n "$ISTIO_NS" --patch-file "$TEMP_PATCH"
fi

# Verify the configuration
sleep 2
if kubectl get cm "$CONFIGMAP_NAME" -n "$ISTIO_NS" -o jsonpath='{.data.mesh}' | grep -q "$PROVIDER_NAME"; then
  echo "✓ Successfully configured extension provider '$PROVIDER_NAME'"
  echo ""
  echo "IMPORTANT: Restart istiod for changes to take effect:"
  echo "  kubectl rollout restart deployment/istiod -n $ISTIO_NS"
  echo ""
  echo "Or wait for istiod to automatically detect the change (may take a few minutes)."
else
  echo "ERROR: Failed to configure extension provider"
  exit 1
fi

echo ""
echo "=== Configuration complete ==="
