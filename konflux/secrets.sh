#!/bin/bash
# ============================================================
# Konflux Secrets Setup for bluefield-ocp
# Run this AFTER creating the namespace and component
# ============================================================
set -euo pipefail

NAMESPACE="${1:?Usage: $0 <tenant-namespace>}"
COMPONENT="bluefield-ocp-421-doca33"
SA="build-pipeline-${COMPONENT}"

echo "=== Setting up secrets in namespace: ${NAMESPACE} ==="

# --- 1. DOCA repo credentials ---
# The build needs auth to access the private DOCA RPM repository
echo ""
echo "--- DOCA repo credentials ---"
read -p "Enter DOCA repo username:password (or press Enter to skip): " DOCA_CREDS
if [ -n "${DOCA_CREDS}" ]; then
  kubectl create secret generic d-doca-baseurl-auth-creds \
    --from-literal=username-and-password="${DOCA_CREDS}" \
    -n "${NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Link to the component service account
  kubectl patch sa "${SA}" -n "${NAMESPACE}" \
    -p "{\"secrets\":[{\"name\":\"d-doca-baseurl-auth-creds\"}]}" \
    --type=merge 2>/dev/null || echo "  (SA not yet created - link after component is created)"

  echo "  Created and linked d-doca-baseurl-auth-creds"
else
  echo "  Skipped"
fi

# --- 2. Registry pull secret (registry.redhat.io) ---
echo ""
echo "--- Registry pull secret ---"
echo "  Create via Konflux UI: Secrets > Add secret > Image pull secret"
echo "  Registry: registry.redhat.io"
echo "  Also add: quay.io/openshift-release-dev (for base images)"
echo "  Link to: ${SA}"

# --- 3. Quay.io push secret for dev releases ---
echo ""
echo "--- Quay.io dev release push secret ---"
read -p "Enter quay.io robot username (or press Enter to skip): " QUAY_USER
if [ -n "${QUAY_USER}" ]; then
  read -s -p "Enter quay.io robot token: " QUAY_TOKEN
  echo ""
  kubectl create secret docker-registry release-registry-secret \
    --docker-server=quay.io \
    --docker-username="${QUAY_USER}" \
    --docker-password="${QUAY_TOKEN}" \
    -n "${NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "  Created release-registry-secret"
else
  echo "  Skipped"
fi

echo ""
echo "=== Done ==="
echo ""
echo "Next steps:"
echo "  1. Apply the application: kubectl apply -f konflux/application.yaml -n ${NAMESPACE}"
echo "  2. Wait for component to be ready: kubectl get component ${COMPONENT} -n ${NAMESPACE}"
echo "  3. Verify build triggers by pushing to 4.21.x-DOCA-3.3 branch"
