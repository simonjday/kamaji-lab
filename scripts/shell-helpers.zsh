#!/usr/bin/env zsh
# shell-helpers.zsh — Kamaji lab kubectl context helpers (kind edition)
#
# Add to ~/.zshrc:
#   source "/path/to/kamaji-lab/scripts/shell-helpers.zsh"

export KUBECONFIG_MGMT="${HOME}/.kube/config"

function use-mgmt() {
  export KUBECONFIG="${HOME}/.kube/config"
  # Auto-recover kind context if missing (lost after teardown/restart)
  if ! kubectl config get-contexts kind-kamaji-mgmt &>/dev/null 2>&1; then
    echo "==> Re-exporting kind context"
    kind export kubeconfig --name kamaji-mgmt 2>/dev/null || \
      echo "ERROR: kind-kamaji-mgmt cluster not found. Run: ./scripts/setup-kind-kamaji.sh"
  fi
  kubectl config use-context kind-kamaji-mgmt 2>/dev/null || \
    echo "ERROR: kind-kamaji-mgmt context not found."
  echo "==> Management: $(kubectl config current-context 2>/dev/null)"
}

function _validate_tenant_kubeconfig() {
  local KUBECONFIG_LOCAL="${1}"
  local TCP="${2}"

  # Check file exists and has correct server entry
  if [ ! -f "${KUBECONFIG_LOCAL}" ]; then
    return 1
  fi

  # Check it contains a server entry pointing at localhost (not management cluster)
  if ! grep -q "server: https://127.0.0.1:" "${KUBECONFIG_LOCAL}" 2>/dev/null; then
    echo "WARNING: Tenant kubeconfig is corrupt or pointing at wrong server — regenerating"
    return 1
  fi

  return 0
}

function use-tenant() {
  local TCP=${1:?"Usage: use-tenant <tcp-name> [namespace] [port]"}
  local NS=${2:-${TCP}}
  local PORT=${3:-7443}
  local MGMT="${HOME}/.kube/config"
  local KUBECONFIG_RAW="${HOME}/.kube/${TCP}.kubeconfig"
  local KUBECONFIG_LOCAL="${HOME}/.kube/${TCP}-local.kubeconfig"

  # Kill existing port-forward on this port
  lsof -ti:${PORT} | xargs kill -9 2>/dev/null || true
  sleep 1

  # Validate and regenerate kubeconfig if needed
  if ! _validate_tenant_kubeconfig "${KUBECONFIG_LOCAL}" "${TCP}"; then
    echo "==> Extracting kubeconfig for ${TCP}"
    KUBECONFIG=${MGMT} kubectl get secret ${TCP}-admin-kubeconfig -n ${NS} \
      -o jsonpath='{.data.admin\.conf}' | base64 -d > "${KUBECONFIG_RAW}"

    local TCP_ENDPOINT
    TCP_ENDPOINT=$(KUBECONFIG=${MGMT} kubectl get tcp "${TCP}" -n "${NS}" \
      -o jsonpath='{.status.controlPlaneEndpoint}' 2>/dev/null)

    if [ -z "${TCP_ENDPOINT}" ]; then
      echo "ERROR: TCP '${TCP}' not found or not Ready in namespace '${NS}'"
      return 1
    fi

    sed "s|https://${TCP_ENDPOINT}|https://127.0.0.1:${PORT}|g" \
      "${KUBECONFIG_RAW}" > "${KUBECONFIG_LOCAL}"
    chmod 600 "${KUBECONFIG_RAW}" "${KUBECONFIG_LOCAL}"
    echo "==> Kubeconfig regenerated"
  fi

  echo "==> Starting port-forward :${PORT} → ${TCP}:6443"
  KUBECONFIG=${MGMT} kubectl port-forward svc/${TCP} -n ${NS} \
    ${PORT}:6443 --address 127.0.0.1 >/dev/null 2>&1 &
  sleep 2

  export KUBECONFIG=${KUBECONFIG_LOCAL}
  kubectl config use-context "kubernetes-admin@${TCP}" 2>/dev/null || true
  echo "==> Switched to: $(kubectl config current-context)"
  kubectl get nodes
}

function kamaji-status() {
  echo "==> Tenant Control Planes"
  KUBECONFIG=${KUBECONFIG_MGMT} kubectl get tcp -A
  echo ""
  echo "==> Management pods"
  KUBECONFIG=${KUBECONFIG_MGMT} kubectl get pods -n kamaji-system
  echo ""
  echo "==> Worker containers"
  docker ps --filter "name=kamaji-worker" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
}

function kamaji-ui() {
  local PORT=${1:-8080}
  lsof -ti:${PORT} | xargs kill -9 2>/dev/null || true
  KUBECONFIG=${KUBECONFIG_MGMT} kubectl port-forward \
    -n kamaji-system svc/kamaji-console ${PORT}:80 >/dev/null 2>&1 &
  sleep 2
  open "http://localhost:${PORT}/ui"
  echo "==> Kamaji Console: http://localhost:${PORT}/ui (admin@lab.local / admin123)"
}

function reset-tenant() {
  local TCP=${1:?"Usage: reset-tenant <tcp-name>"}
  rm -f "${HOME}/.kube/${TCP}.kubeconfig" "${HOME}/.kube/${TCP}-local.kubeconfig"
  pkill -f "kubectl port-forward svc/${TCP}" 2>/dev/null || true
  echo "==> Reset: ${TCP}"
}
