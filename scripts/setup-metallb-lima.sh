#!/usr/bin/env bash
# setup-metallb-lima.sh — Install MetalLB for Lima or Rancher Desktop K3s
# IPs assigned by MetalLB ARE directly routable from your macOS terminal.
# No port-forward workarounds needed (unlike kind).
# Run AFTER: setup-lima-k3s.sh or setup-rancher.sh
set -euo pipefail

echo "==> Installing MetalLB"
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.3/config/manifests/metallb-native.yaml
kubectl rollout status daemonset/speaker -n metallb-system --timeout=180s

echo "==> Detecting node IP"
NODE_IP=$(kubectl get nodes \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

if [ -z "${NODE_IP}" ]; then
  echo "ERROR: Could not detect node IP. Is the cluster running?"
  exit 1
fi

echo "==> Node IP: ${NODE_IP}"

# Assign pool in the same /24 as the node, last 50 addresses
NET_PREFIX=$(echo "${NODE_IP}" | cut -d. -f1-3)
POOL_START="${NET_PREFIX}.200"
POOL_END="${NET_PREFIX}.250"

echo "==> MetalLB pool: ${POOL_START}-${POOL_END}"

cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lima-pool
  namespace: metallb-system
spec:
  addresses:
    - ${POOL_START}-${POOL_END}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: lima-l2
  namespace: metallb-system
EOF

echo ""
echo "==> MetalLB ready"
echo ""
echo "    Pool: ${POOL_START}-${POOL_END}"
echo "    These IPs are DIRECTLY ROUTABLE from your Mac terminal."
echo "    No port-forward or docker exec needed."
echo ""
echo "    After creating a TenantControlPlane, test with:"
echo "    kubectl get tcp -A  # get the ENDPOINT column"
echo "    curl -k https://<TCP_ENDPOINT>/version"
