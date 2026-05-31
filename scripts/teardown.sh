#!/usr/bin/env bash
# teardown.sh — Destroy the Kamaji lab environment
#
# Usage:
#   ./scripts/teardown.sh                        — full teardown (cluster + all workers + kubeconfigs)
#   ./scripts/teardown.sh cluster                — delete kind cluster only
#   ./scripts/teardown.sh worker                 — delete default worker (kamaji-worker-01)
#   ./scripts/teardown.sh worker kamaji-worker-02 — delete a specific worker
#   ./scripts/teardown.sh configs                — remove kubeconfigs only

set -euo pipefail

MODE="${1:-all}"
CLUSTER_NAME="kamaji-mgmt"
DEFAULT_WORKER="kamaji-worker-01"

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
  local NAME="${1:-${DEFAULT_WORKER}}"
  echo "==> Removing Docker worker container: ${NAME}"
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${NAME}$"; then
    docker rm -f "${NAME}"
    echo "==> Worker container '${NAME}' removed"
  else
    echo "==> Worker container '${NAME}' not found — skipping"
  fi
}

teardown_all_workers() {
  # Find and remove all kamaji-worker-* containers
  local WORKERS
  WORKERS=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep '^kamaji-worker-' || true)
  if [ -z "${WORKERS}" ]; then
    echo "==> No kamaji-worker-* containers found — skipping"
  else
    echo "${WORKERS}" | while read -r W; do
      echo "==> Removing worker container: ${W}"
      docker rm -f "${W}"
    done
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
    echo "==> Full teardown: kind cluster + all workers + kubeconfigs"
    teardown_all_workers
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
    # Optional second arg is the worker name
    teardown_worker "${2:-${DEFAULT_WORKER}}"
    ;;
  configs)
    teardown_configs
    ;;
  *)
    echo "Usage: $0 [all|cluster|worker|configs] [worker-name]"
    echo ""
    echo "  all                          — delete kind cluster, all workers, and kubeconfigs (default)"
    echo "  cluster                      — delete kind cluster only"
    echo "  worker                       — delete default worker (${DEFAULT_WORKER})"
    echo "  worker kamaji-worker-02      — delete a specific worker container"
    echo "  configs                      — remove tenant kubeconfigs only"
    echo ""
    echo "Examples:"
    echo "  $0                           # full teardown"
    echo "  $0 worker                    # remove kamaji-worker-01"
    echo "  $0 worker kamaji-worker-02   # remove kamaji-worker-02"
    exit 1
    ;;
esac
