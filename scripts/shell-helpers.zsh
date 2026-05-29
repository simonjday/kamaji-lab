#!/usr/bin/env zsh
# shell-helpers.zsh — Kamaji lab kubectl context helpers (kind edition)
#
# Add to ~/.zshrc:
#   source "/path/to/kamaji-lab/scripts/shell-helpers.zsh"

export KUBECONFIG_MGMT="${HOME}/.kube/config"

alias use-mgmt='kubectl config use-context kind-kamaji-mgmt && echo "==> Management: $(kubectl config current-context)"'

function use-tenant() {
  local TCP=${1:?"Usage: use-tenant <tcp-name> [namespace] [port]"}
  local NS=${2:-${TCP}}
  local PORT=${3:-7443}
  local MGMT="${HOME}/.kube/config"
  local KUBECONFIG_RAW="${HOME}/.kube/${TCP}.kubeconfig"
  local KUBECONFIG_LOCAL="${HOME}/.kube/${TCP}-local.kubeconfig"

  lsof -ti:${PORT} | xargs kill -9 2>/dev/null || true
  sleep 1

  if [ ! -f "${KUBECONFIG_LOCAL}" ]; then
    echo "==> Extracting kubeconfig for ${TCP}"
    KUBECONFIG=${MGMT} kubectl get secret ${TCP}-admin-kubeconfig -n ${NS} \
      -o jsonpath='{.data.admin\.conf}' | base64 -d > "${KUBECONFIG_RAW}"

    local TCP_ENDPOINT
    TCP_ENDPOINT=$(KUBECONFIG=${MGMT} kubectl get tcp "${TCP}" -n "${NS}" \
      -o jsonpath='{.status.controlPlaneEndpoint}' 2>/dev/null)
    sed "s|https://${TCP_ENDPOINT}|https://127.0.0.1:${PORT}|g" \
      "${KUBECONFIG_RAW}" > "${KUBECONFIG_LOCAL}"
    chmod 600 "${KUBECONFIG_RAW}" "${KUBECONFIG_LOCAL}"
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
