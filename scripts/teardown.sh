#!/usr/bin/env bash
# teardown.sh — Destroy the Kamaji lab environment
# Usage: ./teardown.sh <kind|rancher|lima> [cluster/vm-name]
#   ./teardown.sh kind kamaji-mgmt
#   ./teardown.sh lima kamaji-k3s
#   ./teardown.sh rancher
set -euo pipefail

BASE="${1:-kind}"
NAME="${2:-}"

case "${BASE}" in

  kind)
    CLUSTER="${NAME:-kamaji-mgmt}"
    echo "==> Deleting kind cluster: ${CLUSTER}"
    kind delete cluster --name "${CLUSTER}"
    echo "==> Done"
    ;;

  lima)
    VM="${NAME:-kamaji-k3s}"
    KUBECONFIG_PATH="${HOME}/.kube/k3s-kamaji.kubeconfig"
    echo "==> Stopping Lima VM: ${VM}"
    limactl stop "${VM}" 2>/dev/null || true
    echo "==> Deleting Lima VM: ${VM}"
    limactl delete "${VM}"
    if [ -f "${KUBECONFIG_PATH}" ]; then
      rm -f "${KUBECONFIG_PATH}"
      echo "==> Removed kubeconfig: ${KUBECONFIG_PATH}"
    fi
    echo "==> Done"
    ;;

  rancher)
    echo "==> Resetting Rancher Desktop Kubernetes cluster"
    echo "    This deletes all workloads and resets to factory state."
    read -rp "    Are you sure? (yes/no): " CONFIRM
    if [ "${CONFIRM}" != "yes" ]; then
      echo "Aborted."
      exit 0
    fi
    rdctl set --kubernetes.enabled=false
    sleep 5
    rdctl set --kubernetes.enabled=true
    echo "==> Done — Rancher Desktop cluster reset"
    ;;

  *)
    echo "Usage: $0 <kind|rancher|lima> [cluster/vm-name]"
    echo ""
    echo "Examples:"
    echo "  $0 kind kamaji-mgmt"
    echo "  $0 lima kamaji-k3s"
    echo "  $0 rancher"
    exit 1
    ;;

esac
