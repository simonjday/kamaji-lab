#!/usr/bin/env bash
# setup-metallb-kind.sh — Install and configure MetalLB for a kind cluster
# MetalLB IPs will be inside the Docker bridge network.
# Run AFTER: setup-kind.sh
# See Section 8 of the docs for how to reach these IPs from your Mac terminal.
set -euo pipefail

echo "==> Installing MetalLB"
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.3/config/manifests/metallb-native.yaml
kubectl rollout status daemonset/speaker -n metallb-system --timeout=120s

echo "==> Detecting kind network gateway"
GW_IP=$(docker network inspect -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' kind)
NET_IP=$(echo "${GW_IP}" | sed -E 's|^([0-9]+\.[0-9]+)\..*$|\1|g')
POOL_START="${NET_IP}.255.200"
POOL_END="${NET_IP}.255.250"

echo "==> Creating IPAddressPool: ${POOL_START}-${POOL_END}"

cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
    - ${POOL_START}-${POOL_END}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-l2
  namespace: metallb-system
EOF

echo ""
echo "==> MetalLB ready"
echo "    Pool: ${POOL_START}-${POOL_END}"
echo "    WARNING: These IPs are inside the Docker VM — not directly reachable from macOS."
echo "    Use port-forward, docker exec, or static route (see Section 8)."
