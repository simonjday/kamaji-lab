#!/usr/bin/env bash
# setup-kamaji-console.sh — Install Kamaji Console on the management cluster
#
# Usage: ./scripts/setup-kamaji-console.sh [admin-email] [admin-password] [port]

set -euo pipefail

ADMIN_EMAIL="${1:-admin@lab.local}"
ADMIN_PASSWORD="${2:-admin123}"
LOCAL_PORT="${3:-8080}"
NAMESPACE="kamaji-system"

echo "==> Installing Kamaji Console"
echo "    Email:    ${ADMIN_EMAIL}"
echo "    Password: ${ADMIN_PASSWORD}"
echo "    Port:     ${LOCAL_PORT}"
echo ""

if echo "${ADMIN_PASSWORD}" | grep -qE '[^a-zA-Z0-9]'; then
  echo "WARNING: Password contains non-alphanumeric characters — may cause auth failure"
fi

helm repo add clastix https://clastix.github.io/charts 2>/dev/null || true
helm repo update clastix

if kubectl get secret kamaji-console -n "${NAMESPACE}" &>/dev/null 2>&1; then
  kubectl delete secret kamaji-console -n "${NAMESPACE}"
fi

kubectl create secret generic kamaji-console \
  --namespace "${NAMESPACE}" \
  --from-literal=NEXTAUTH_URL="http://localhost:${LOCAL_PORT}" \
  --from-literal=JWT_SECRET="$(openssl rand -hex 32)" \
  --from-literal=ADMIN_EMAIL="${ADMIN_EMAIL}" \
  --from-literal=ADMIN_PASSWORD="${ADMIN_PASSWORD}"

helm upgrade --install kamaji-console clastix/kamaji-console \
  --namespace "${NAMESPACE}" \
  --set replicaCount=1 \
  --set credentialsSecret.generate=false \
  --set credentialsSecret.name=kamaji-console \
  --wait

echo ""
echo "======================================================"
echo " Kamaji Console installed"
echo " Start:  kubectl port-forward -n ${NAMESPACE} svc/kamaji-console ${LOCAL_PORT}:80 &"
echo " Open:   http://localhost:${LOCAL_PORT}/ui"
echo " Login:  ${ADMIN_EMAIL} / ${ADMIN_PASSWORD}"
echo " Or use: kamaji-ui"
echo "======================================================"
