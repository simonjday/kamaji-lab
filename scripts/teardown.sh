#!/usr/bin/env bash
# teardown.sh — Destroy the Kamaji lab environment
#
# Usage:
#   ./scripts/teardown.sh           — full teardown (cluster + worker + kubeconfigs)
#   ./scripts/teardown.sh cluster   — delete kind cluster only
#   ./scripts/teardown.sh worker    — delete Docker worker container only
#   ./scripts/teardown.sh configs   — remove kubeconfigs only

set -euo pipefail

MODE="${1:-all}"
CLUSTER_NAME="kamaji-mgmt"
WORKER_NAME="kamaji-worker-01"

teardown_cluster() {
  echo "==> Deleting kind cluster: ${CLUSTER_NAME}"
  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    kind delete cluster --name "${CLUSTER_NAME}"
    echo "==> Kind cluster deleted"
  else
    echo "==> Kind cluster '${CLUSTER_NAME}' not found — skipping"
  fi
}

teardown_worker() {
  echo "==> Removing Docker worker container: ${WORKER_NAME}"
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${WORKER_NAME}$"; then
    docker rm -f "${WORKER_NAME}"
    echo "==> Worker container removed"
  else
    echo "==> Worker container '${WORKER_NAME}' not found — skipping"
  fi
}

teardown_configs() {
  echo "==> Removing kubeconfigs"
  rm -f "${HOME}/.kube/tenant-demo.kubeconfig" \
        "${HOME}/.kube/tenant-demo-local.kubeconfig"
  kubectl config delete-context "kind-${CLUSTER_NAME}" 2>/dev/null || true
  kubectl config delete-cluster "kind-${CLUSTER_NAME}" 2>/dev/null || true
  echo "==> Kubeconfigs removed"
}

case "${MODE}" in
  all)
    echo "==> Full teardown: kind cluster + Docker worker + kubeconfigs"
    teardown_worker
    teardown_cluster
    teardown_configs
    echo ""
    echo "==> Teardown complete. To rebuild:"
    echo "    ./scripts/setup-kind-kamaji.sh"
    ;;
  cluster)
    teardown_cluster
    ;;
  worker)
    teardown_worker
    ;;
  configs)
    teardown_configs
    ;;
  *)
    echo "Usage: $0 [all|cluster|worker|configs]"
    echo ""
    echo "  all     — delete kind cluster, Docker worker, and kubeconfigs (default)"
    echo "  cluster — delete kind cluster only"
    echo "  worker  — delete Docker worker container only"
    echo "  configs — remove tenant kubeconfigs only"
    exit 1
    ;;
esac
