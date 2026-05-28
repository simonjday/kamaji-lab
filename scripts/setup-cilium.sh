#!/usr/bin/env bash
# setup-cilium.sh — Install Cilium CNI (Lima or Rancher Desktop base)
# Requires: A K3s cluster started with --flannel-backend=none --disable-network-policy
# Usage: ./setup-cilium.sh
set -euo pipefail

# Install Cilium CLI if not present
install_cilium_cli() {
  local version
  version=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
  local arch
  arch=$(uname -m)
  local os_name
  os_name=$(uname -s | tr '[:upper:]' '[:lower:]')

  case "${arch}" in
    arm64|aarch64) arch="arm64" ;;
    x86_64)        arch="amd64" ;;
    *) echo "ERROR: Unsupported arch: ${arch}"; exit 1 ;;
  esac

  echo "==> Downloading Cilium CLI ${version} (${os_name}/${arch})"
  curl -L --remote-name \
    "https://github.com/cilium/cilium-cli/releases/download/${version}/cilium-${os_name}-${arch}.tar.gz"
  tar xzf "cilium-${os_name}-${arch}.tar.gz"
  sudo mv cilium /usr/local/bin/
  rm -f "cilium-${os_name}-${arch}.tar.gz"
  echo "==> Cilium CLI installed: $(cilium version --client)"
}

if ! command -v cilium &>/dev/null; then
  install_cilium_cli
else
  echo "==> Cilium CLI already installed: $(cilium version --client)"
fi

# Get the API server IP from the current kubeconfig
CONTEXT=$(kubectl config current-context)
API_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
API_IP=$(echo "${API_SERVER}" | sed -E 's|https?://([^:]+).*|\1|')
API_PORT=$(echo "${API_SERVER}" | sed -E 's|.*:([0-9]+).*|\1|')

echo ""
echo "==> Installing Cilium"
echo "    Context:    ${CONTEXT}"
echo "    API server: ${API_IP}:${API_PORT}"

cilium install \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="${API_IP}" \
  --set k8sServicePort="${API_PORT}" \
  --set ipam.mode=kubernetes \
  --set operator.replicas=1

echo ""
echo "==> Waiting for Cilium to be ready..."
cilium status --wait

echo ""
echo "==> Cilium installed successfully"
cilium status

echo ""
echo "==> To enable Hubble observability:"
echo "    cilium hubble enable --ui"
echo "    cilium hubble ui    # opens browser with service map"
