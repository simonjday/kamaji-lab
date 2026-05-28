#!/usr/bin/env zsh
# shell-helpers.zsh — Kamaji lab kubectl context helpers
#
# Add to ~/.zshrc:
#   source "/path/to/kamaji-lab/scripts/shell-helpers.zsh"
#
# Commands:
#   use-mgmt                            — switch to management cluster
#   use-tenant tenant-demo              — switch to tenant (starts port-forwards)
#   use-tenant tenant-demo default 7443 16443 — custom ports
#   kamaji-status                       — show all TCPs + pod status
#   reset-tenant tenant-demo            — clear kubeconfig cache

export KUBECONFIG_MGMT="${HOME}/.kube/k3s-kamaji.kubeconfig"

alias use-mgmt='export KUBECONFIG=${KUBECONFIG_MGMT} && kubectl config use-context kamaji-k3s && echo "==> Management cluster: $(kubectl config current-context)"'

function use-tenant() {
  local TCP=${1:?"Usage: use-tenant <tcp-name> [namespace] [kubectl-port] [worker-port]"}
  local NS=${2:-${TCP}}
  local KUBECTL_PORT=${3:-7443}    # for your kubectl commands
  local WORKER_PORT=${4:-16443}    # for worker kubelet (0.0.0.0 bound)
  local MGMT="${HOME}/.kube/k3s-kamaji.kubeconfig"
  local KUBECONFIG_RAW="${HOME}/.kube/${TCP}.kubeconfig"
  local KUBECONFIG_LOCAL="${HOME}/.kube/${TCP}-local.kubeconfig"

  # Kill any existing forwards on these ports
  lsof -ti:${KUBECTL_PORT} | xargs kill -9 2>/dev/null || true
  lsof -ti:${WORKER_PORT}  | xargs kill -9 2>/dev/null || true
  sleep 1

  # Extract kubeconfig if not already done
  if [ ! -f "${KUBECONFIG_LOCAL}" ]; then
    echo "==> Extracting kubeconfig for ${TCP}"
    KUBECONFIG=${MGMT} kubectl get secret ${TCP}-admin-kubeconfig -n ${NS} \
      -o jsonpath='{.data.admin\.conf}' | base64 -d > "${KUBECONFIG_RAW}"
    if [ ! -s "${KUBECONFIG_RAW}" ]; then
      echo "ERROR: kubeconfig extraction failed"
      return 1
    fi
    local TCP_ENDPOINT
    TCP_ENDPOINT=$(KUBECONFIG=${MGMT} kubectl get tcp "${TCP}" -n "${NS}" \
      -o jsonpath='{.status.controlPlaneEndpoint}' 2>/dev/null)
    sed "s|https://${TCP_ENDPOINT}|https://127.0.0.1:${KUBECTL_PORT}|g" \
      "${KUBECONFIG_RAW}" > "${KUBECONFIG_LOCAL}"
    chmod 600 "${KUBECONFIG_RAW}" "${KUBECONFIG_LOCAL}"
  fi

  # Start kubectl port-forward (localhost only)
  echo "==> Starting kubectl port-forward :${KUBECTL_PORT} → ${TCP}:6443"
  KUBECONFIG=${MGMT} kubectl port-forward svc/${TCP} -n ${NS} \
    ${KUBECTL_PORT}:6443 --address 127.0.0.1 >/dev/null 2>&1 &
  sleep 1

  # Start worker port-forward (all interfaces — for Multipass kubelet)
  echo "==> Starting worker port-forward :${WORKER_PORT} → ${TCP}:6443 (0.0.0.0)"
  KUBECONFIG=${MGMT} kubectl port-forward svc/${TCP} -n ${NS} \
    ${WORKER_PORT}:6443 --address 0.0.0.0 >/dev/null 2>&1 &
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
  echo "==> Management cluster pods"
  KUBECONFIG=${KUBECONFIG_MGMT} kubectl get pods -n kamaji-system
  KUBECONFIG=${KUBECONFIG_MGMT} kubectl get pods -n kamaji-etcd
}

function kamaji-ui() {
  local PORT=${1:-8080}
  lsof -ti:${PORT} | xargs kill -9 2>/dev/null || true
  kubectl port-forward -n kamaji-system svc/kamaji-console ${PORT}:80     --kubeconfig ${KUBECONFIG_MGMT} >/dev/null 2>&1 &
  sleep 2
  open "http://localhost:${PORT}/ui"
  echo "==> Kamaji Console: http://localhost:${PORT}/ui"
  echo "    Login: admin@lab.local / admin123"
}

function reset-tenant() {
  local TCP=${1:?"Usage: reset-tenant <tcp-name>"}
  rm -f "${HOME}/.kube/${TCP}.kubeconfig" "${HOME}/.kube/${TCP}-local.kubeconfig"
  pkill -f "kubectl port-forward svc/${TCP}" 2>/dev/null || true
  echo "==> Cleared kubeconfig cache and port-forwards for ${TCP}"
}
