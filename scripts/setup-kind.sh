#!/usr/bin/env bash
# setup-kind.sh — Create a kind management cluster for Kamaji lab
# Usage: CLUSTER_NAME=my-cluster ./setup-kind.sh
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-kamaji-mgmt}"

echo "==> Creating kind cluster: ${CLUSTER_NAME}"

cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 16443   # management API passthrough
        hostPort: 16443
        protocol: TCP
      - containerPort: 30001   # tenant-01 TCP (NodePort fallback)
        hostPort: 7443
        protocol: TCP
      - containerPort: 30002   # tenant-02 TCP
        hostPort: 7444
        protocol: TCP
      - containerPort: 30003   # tenant-03 TCP
        hostPort: 7445
        protocol: TCP
      - containerPort: 30080   # Kamaji Console
        hostPort: 8080
        protocol: TCP
EOF

kubectl config use-context "kind-${CLUSTER_NAME}"

echo ""
echo "==> kind cluster ready"
kubectl get nodes -o wide
echo ""
echo "==> Next steps:"
echo "    1. Run: ./setup-metallb-kind.sh"
echo "    2. Run: ./install-kamaji.sh"
echo ""
echo "    NOTE: MetalLB IPs will only be reachable via port-forward or docker exec"
echo "    from your macOS terminal. See Section 8 of the docs for workarounds."
echo "    For direct IP access, use Lima or Rancher Desktop instead."
