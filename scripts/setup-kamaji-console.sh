#!/usr/bin/env bash
# setup-kamaji-console.sh — Install Kamaji Console web UI on the management cluster
#
# Tested on: Kamaji Console v0.2.1 (chart 0.1.3), Lima K3s management cluster
#
# Gotchas discovered during lab:
#   - Secret key must be JWT_SECRET (not NEXTAUTH_SECRET)
#   - credentialsSecret.generate=true is broken in chart v0.1.3 — create secret manually
#   - App serves on /ui subpath — access http://localhost:8080/ui
#   - Password must be alphanumeric — dots/special chars cause silent auth failure
#   - NEXTAUTH_URL must match exactly how you access the console
#
# Usage: ./scripts/setup-kamaji-console.sh [admin-email] [admin-password] [port]

set -euo pipefail

ADMIN_EMAIL="${1:-admin@lab.local}"
ADMIN_PASSWORD="${2:-admin123}"
LOCAL_PORT="${3:-8080}"
NAMESPACE="kamaji-system"

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/k3s-kamaji.kubeconfig}"

echo "==> Installing Kamaji Console"
echo "    Context:  $(kubectl config current-context)"
echo "    Email:    ${ADMIN_EMAIL}"
echo "    Password: ${ADMIN_PASSWORD}"
echo "    Port:     ${LOCAL_PORT}"
echo ""

# ── Validate password ─────────────────────────────────────────────────────────
if echo "${ADMIN_PASSWORD}" | grep -qE '[^a-zA-Z0-9]'; then
  echo "WARNING: Password contains non-alphanumeric characters"
  echo "         This can cause silent auth failures on the login page"
  echo "         Recommend using only letters and numbers"
fi

# ── Helm repo ─────────────────────────────────────────────────────────────────
helm repo add clastix https://clastix.github.io/charts 2>/dev/null || true
helm repo update clastix

# ── Create secret with correct key names ─────────────────────────────────────
if kubectl get secret kamaji-console -n "${NAMESPACE}" &>/dev/null 2>&1; then
  echo "==> Secret 'kamaji-console' already exists — deleting and recreating"
  kubectl delete secret kamaji-console -n "${NAMESPACE}"
fi

echo "==> Creating kamaji-console secret"
kubectl create secret generic kamaji-console \
  --namespace "${NAMESPACE}" \
  --from-literal=NEXTAUTH_URL="http://localhost:${LOCAL_PORT}" \
  --from-literal=JWT_SECRET="$(openssl rand -hex 32)" \
  --from-literal=ADMIN_EMAIL="${ADMIN_EMAIL}" \
  --from-literal=ADMIN_PASSWORD="${ADMIN_PASSWORD}"

echo "==> Secret created with keys: NEXTAUTH_URL, JWT_SECRET, ADMIN_EMAIL, ADMIN_PASSWORD"

# ── Install Helm chart ────────────────────────────────────────────────────────
echo "==> Installing kamaji-console Helm chart"

helm upgrade --install kamaji-console clastix/kamaji-console \
  --namespace "${NAMESPACE}" \
  --set replicaCount=1 \
  --set credentialsSecret.generate=false \
  --set credentialsSecret.name=kamaji-console \
  --wait

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
echo "==> Verifying installation"
kubectl get pods -n "${NAMESPACE}" | grep console

echo ""
echo "==> Checking pod logs for errors"
sleep 3
CONSOLE_POD=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=kamaji-console \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "${CONSOLE_POD}" ]; then
  kubectl logs -n "${NAMESPACE}" "${CONSOLE_POD}" --tail=5
fi

echo ""
echo "======================================================"
echo " Kamaji Console installed"
echo "======================================================"
echo ""
echo " Start port-forward and open:"
echo "   kubectl port-forward -n ${NAMESPACE} svc/kamaji-console ${LOCAL_PORT}:80 &"
echo "   open http://localhost:${LOCAL_PORT}/ui"
echo ""
echo " Login:"
echo "   Email:    ${ADMIN_EMAIL}"
echo "   Password: ${ADMIN_PASSWORD}"
echo ""
echo " Add to shell-helpers.zsh:"
echo "   alias kamaji-ui='kubectl port-forward -n ${NAMESPACE} svc/kamaji-console ${LOCAL_PORT}:80"
echo "     --kubeconfig \${KUBECONFIG_MGMT} & sleep 1 && open http://localhost:${LOCAL_PORT}/ui'"
echo "======================================================"
