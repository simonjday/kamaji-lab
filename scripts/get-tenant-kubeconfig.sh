#!/usr/bin/env bash
# get-tenant-kubeconfig.sh — Extract kubeconfig for a Kamaji TenantControlPlane
# Handles Lima usernet port-forward automatically.
#
# Usage: ./scripts/get-tenant-kubeconfig.sh <tcp-name> <namespace> [local-port]
#
# Examples:
#   ./scripts/get-tenant-kubeconfig.sh tenant-demo tenant-demo
#   ./scripts/get-tenant-kubeconfig.sh tenant-demo tenant-demo 7443
#
# Output:
#   ~/.kube/<tcp-name>.kubeconfig          — raw kubeconfig (direct IP)
#   ~/.kube/<tcp-name>-local.kubeconfig    — patched for localhost port-forward
#
# After running, use:
#   export KUBECONFIG=~/.kube/<tcp-name>-local.kubeconfig
#   kubectl get namespaces

set -euo pipefail

TCP_NAME="${1:-}"
NAMESPACE="${2:-}"
LOCAL_PORT="${3:-7443}"

if [ -z "${TCP_NAME}" ] || [ -z "${NAMESPACE}" ]; then
  echo "Usage: $0 <tcp-name> <namespace> [local-port]"
  echo "  Example: $0 tenant-demo tenant-demo 7443"
  exit 1
fi

KUBECONFIG_RAW="${HOME}/.kube/${TCP_NAME}.kubeconfig"
KUBECONFIG_LOCAL="${HOME}/.kube/${TCP_NAME}-local.kubeconfig"

# ── Verify we're on the management cluster ─────────────────────────────────────
CONTEXT=$(kubectl config current-context 2>/dev/null || echo "")
echo "==> Management cluster context: ${CONTEXT}"
echo "==> Extracting kubeconfig for TCP: ${TCP_NAME} (namespace: ${NAMESPACE})"

# ── Check TCP is Ready ─────────────────────────────────────────────────────────
TCP_STATUS=$(kubectl get tcp "${TCP_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{.status.kubernetesResources.version.status}' 2>/dev/null || echo "NotFound")

if [ "${TCP_STATUS}" != "Ready" ]; then
  echo "WARNING: TCP status is '${TCP_STATUS}' (expected Ready)"
  echo "         Proceeding anyway — kubeconfig may not work until TCP is Ready"
fi

# ── Extract raw kubeconfig from secret ────────────────────────────────────────
echo "==> Extracting from secret: ${TCP_NAME}-admin-kubeconfig"
kubectl get secret "${TCP_NAME}-admin-kubeconfig" -n "${NAMESPACE}" \
  -o jsonpath='{.data.admin\.conf}' | base64 -d > "${KUBECONFIG_RAW}"
chmod 600 "${KUBECONFIG_RAW}"

# Verify it has content
if ! grep -q "server:" "${KUBECONFIG_RAW}"; then
  echo "ERROR: Extracted kubeconfig appears empty or invalid"
  echo "       Check: kubectl get secrets -n ${NAMESPACE}"
  exit 1
fi

# ── Get TCP endpoint and context name ─────────────────────────────────────────
TCP_ENDPOINT=$(kubectl get tcp "${TCP_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{.status.controlPlaneEndpoint}')
TCP_CONTEXT=$(KUBECONFIG="${KUBECONFIG_RAW}" kubectl config get-contexts \
  --no-headers -o name 2>/dev/null | head -1)

echo "==> TCP endpoint:    ${TCP_ENDPOINT}"
echo "==> Kubeconfig context: ${TCP_CONTEXT}"

# ── Test direct connectivity ───────────────────────────────────────────────────
TCP_IP=$(echo "${TCP_ENDPOINT}" | cut -d: -f1)
TCP_PORT=$(echo "${TCP_ENDPOINT}" | cut -d: -f2)
DIRECT_REACHABLE=false

if curl -sk --connect-timeout 3 "https://${TCP_ENDPOINT}/version" &>/dev/null; then
  DIRECT_REACHABLE=true
  echo "==> Direct connectivity: YES (${TCP_ENDPOINT} is reachable from this host)"
  cp "${KUBECONFIG_RAW}" "${KUBECONFIG_LOCAL}"
else
  echo "==> Direct connectivity: NO (Lima usernet / NAT detected)"
  echo "==> Creating port-forward version on localhost:${LOCAL_PORT}"

  # Patch kubeconfig to point at localhost
  sed "s|https://${TCP_ENDPOINT}|https://127.0.0.1:${LOCAL_PORT}|g" \
    "${KUBECONFIG_RAW}" > "${KUBECONFIG_LOCAL}"
  chmod 600 "${KUBECONFIG_LOCAL}"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "======================================================"
echo " Kubeconfig ready: ${TCP_NAME}"
echo "======================================================"
echo ""
echo " Raw kubeconfig (direct IP):"
echo "   ${KUBECONFIG_RAW}"
echo ""

if [ "${DIRECT_REACHABLE}" = "true" ]; then
  echo " Use directly:"
  echo "   export KUBECONFIG=${KUBECONFIG_LOCAL}"
  echo "   kubectl config use-context ${TCP_CONTEXT}"
  echo "   kubectl get namespaces"
else
  echo " Lima usernet detected — port-forward required."
  echo ""
  echo " Step 1: Start port-forward (keep this running in a separate terminal):"
  echo "   export KUBECONFIG=${HOME}/.kube/$(basename "$(ls ~/.kube/*.kubeconfig | grep -v tenant | head -1)" .kubeconfig).kubeconfig"
  echo "   kubectl port-forward svc/${TCP_NAME} -n ${NAMESPACE} ${LOCAL_PORT}:${TCP_PORT}"
  echo ""
  echo " Step 2: Use the patched kubeconfig in another terminal:"
  echo "   export KUBECONFIG=${KUBECONFIG_LOCAL}"
  echo "   kubectl config use-context ${TCP_CONTEXT}"
  echo "   kubectl get namespaces"
  echo ""
  echo " Or install socket_vmnet for direct routing (see Section 8A of the docs)"
fi
echo "======================================================"
