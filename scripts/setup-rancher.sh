#!/usr/bin/env bash
# setup-rancher.sh — Configure Rancher Desktop with K3s for Kamaji lab
# Requires: Rancher Desktop installed (brew install --cask rancher)
# Usage: K8S_VERSION=v1.32.4+k3s1 ./setup-rancher.sh
set -euo pipefail

K8S_VERSION="${K8S_VERSION:-v1.32.4+k3s1}"

# Verify rdctl is available
if ! command -v rdctl &>/dev/null; then
  echo "ERROR: rdctl not found. Install Rancher Desktop first:"
  echo "  brew install --cask rancher"
  exit 1
fi

echo "==> Configuring Rancher Desktop"
echo "    Kubernetes version: ${K8S_VERSION}"
echo "    CNI: Flannel disabled (Cilium will replace)"
echo "    Traefik: disabled"

rdctl set \
  --kubernetes.enabled=true \
  --kubernetes.version="${K8S_VERSION}" \
  --container-engine.name=containerd \
  --kubernetes.options.flannel=false \
  --kubernetes.options.traefik=false

echo "==> Waiting for Rancher Desktop to apply settings and restart K3s (~60s)..."
sleep 30

TIMEOUT=120
ELAPSED=0
until kubectl --context rancher-desktop get nodes --no-headers 2>/dev/null | grep -q Ready; do
  if [ "${ELAPSED}" -ge "${TIMEOUT}" ]; then
    echo "ERROR: Timed out waiting for K3s to be ready"
    exit 1
  fi
  echo "  ... waiting (${ELAPSED}s)"
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

kubectl config use-context rancher-desktop

echo ""
echo "==> Rancher Desktop K3s ready"
kubectl get nodes -o wide

echo ""
echo "==> Next steps:"
echo "    1. Run: ./setup-cilium.sh          (eBPF CNI — needs Flannel disabled)"
echo "    2. Run: ./setup-metallb-rancher.sh (LoadBalancer IPs directly routable)"
echo "    3. Run: ./install-kamaji.sh"
