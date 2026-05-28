#!/usr/bin/env bash
# setup-lima-k3s.sh — Create a Lima VM running K3s for Kamaji lab
# Requires: brew install lima helm kubectl
# Usage: VM_NAME=kamaji-k3s K3S_VERSION=v1.32.4+k3s1 ./setup-lima-k3s.sh
set -euo pipefail

VM_NAME="${VM_NAME:-kamaji-k3s}"
K3S_VERSION="${K3S_VERSION:-v1.32.4+k3s1}"
CPU="${CPU:-4}"
MEMORY="${MEMORY:-8}"
DISK="${DISK:-40}"
KUBECONFIG_PATH="${HOME}/.kube/k3s-kamaji.kubeconfig"
# LIMA_NETWORK=shared  → socket_vmnet bridged network (directly routable from Mac)
# LIMA_NETWORK=usernet → NAT (default, port-forward required)
LIMA_NETWORK="${LIMA_NETWORK:-usernet}"

# ── Detect arch and VM backend ─────────────────────────────────────────────────
case "$(uname -m)" in
  arm64|aarch64) LIMA_ARCH="aarch64"; IMG_ARCH="arm64" ;;
  x86_64)        LIMA_ARCH="x86_64";  IMG_ARCH="amd64" ;;
  *) echo "ERROR: Unsupported architecture: $(uname -m)"; exit 1 ;;
esac

VM_TYPE="qemu"
[[ "$(uname -s)" == "Darwin" ]] && VM_TYPE="vz"

echo "==> Lima version: $(limactl --version)"
echo "==> Arch: $(uname -m) → Lima: ${LIMA_ARCH}, image: ${IMG_ARCH}, vmType: ${VM_TYPE}"

# ── Preflight ──────────────────────────────────────────────────────────────────
if ! command -v limactl &>/dev/null; then
  echo "ERROR: limactl not found.  brew install lima"
  exit 1
fi

# ── Delete any existing stopped/broken VM ─────────────────────────────────────
if limactl list 2>/dev/null | grep -q "^${VM_NAME}"; then
  STATUS=$(limactl list 2>/dev/null | grep "^${VM_NAME}" | awk '{print $2}')
  echo "==> VM '${VM_NAME}' exists (${STATUS})"
  if [ "${STATUS}" = "Running" ]; then
    echo "==> Already running — skipping VM creation"
  else
    echo "==> Deleting stopped/broken VM"
    limactl delete "${VM_NAME}"
  fi
fi

# ── Step 1: Boot a plain Ubuntu VM (no provision script — avoids timeout) ─────
if ! limactl list 2>/dev/null | grep -q "^${VM_NAME}"; then
  echo ""
  echo "==> Step 1/3: Starting Lima VM (Ubuntu only, no K3s yet)"
  echo "    CPUs:    ${CPU}"
  echo "    Memory:  ${MEMORY} GiB"
  echo "    Disk:    ${DISK} GiB"
  echo "    vmType:  ${VM_TYPE}"
  echo ""

  LIMA_YAML=$(mktemp /tmp/kamaji-lima-XXXXXX.yaml)
  trap 'rm -f "${LIMA_YAML}"' EXIT

  # Build network section based on LIMA_NETWORK mode
  if [ "${LIMA_NETWORK}" = "shared" ]; then
    echo "    Network: socket_vmnet shared (IPs directly routable from Mac)"
    NETWORK_SECTION='networks:
  - lima: shared
    interface: lima0'
    PORT_FWD_SECTION=""
  else
    echo "    Network: usernet/NAT (port-forward required to reach MetalLB IPs)"
    NETWORK_SECTION=""
    PORT_FWD_SECTION='portForwards:
  - guestPort: 6443
    hostPort: 6443'
  fi

  cat > "${LIMA_YAML}" <<EOF
vmType: ${VM_TYPE}
os: Linux
arch: ${LIMA_ARCH}

cpus: ${CPU}
memory: "${MEMORY}GiB"
disk: "${DISK}GiB"

images:
  - location: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-${IMG_ARCH}.img"
    arch: ${LIMA_ARCH}

mounts:
  - location: "~"
    writable: false

${NETWORK_SECTION}
${PORT_FWD_SECTION}

provision:
  - mode: system
    script: |
      #!/bin/bash
      # Disable unattended-upgrades so cloud-init finishes quickly
      systemctl disable --now unattended-upgrades apt-daily.service \
        apt-daily-upgrade.service apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
      rm -f /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock
      echo "==> unattended-upgrades disabled"
EOF

  # Start VM — provision script only disables unattended-upgrades (fast)
  # K3s is installed in Step 2 after the VM is confirmed running
  limactl start "${LIMA_YAML}" --name="${VM_NAME}"
  rm -f "${LIMA_YAML}"
  trap - EXIT
fi

# ── Step 2: Install K3s inside the running VM ──────────────────────────────────
echo ""
echo "==> Step 2/3: Installing K3s ${K3S_VERSION} inside VM"

# CNI strategy:
#   CILIUM_CNI=false (default) - use built-in Flannel; node Ready in ~30s
#   CILIUM_CNI=true            - disable Flannel; run setup-cilium.sh before node will be Ready
CILIUM_CNI="${CILIUM_CNI:-false}"
if [ "${CILIUM_CNI}" = "true" ]; then
  EXTRA_K3S_FLAGS="--flannel-backend=none --disable-network-policy"
  echo "    CNI: Cilium mode (Flannel disabled)"
  echo "    NOTE: Node will NOT be Ready until you run setup-cilium.sh"
else
  EXTRA_K3S_FLAGS=""
  echo "    CNI: Flannel (built-in, node Ready in ~30s)"
fi

limactl shell "${VM_NAME}" bash -c "
  set -euo pipefail
  echo '  --> Updating apt cache'
  sudo apt-get update -qq

  echo '  --> Installing K3s'
  export INSTALL_K3S_VERSION='${K3S_VERSION}'
  curl -sfL https://get.k3s.io | sudo sh -s - \
    ${EXTRA_K3S_FLAGS} \
    --disable=traefik \
    --disable=servicelb \
    --write-kubeconfig-mode=644

  echo '  --> K3s install complete'
"


# ── Step 3: Wait for node Ready ───────────────────────────────────────────────
echo ""
echo "==> Step 3/3: Waiting for K3s node to become Ready"
TIMEOUT=120
ELAPSED=0
until limactl shell "${VM_NAME}" sudo k3s kubectl get nodes --no-headers 2>/dev/null | grep -q " Ready"; do
  if [ "${ELAPSED}" -ge "${TIMEOUT}" ]; then
    echo "ERROR: Timed out. Check logs:"
    echo "  limactl shell ${VM_NAME} sudo journalctl -u k3s -n 50"
    exit 1
  fi
  echo "  ... waiting (${ELAPSED}s)"
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done
echo "==> K3s node is Ready"

# ── Extract kubeconfig ─────────────────────────────────────────────────────────
echo ""
echo "==> Extracting kubeconfig to ${KUBECONFIG_PATH}"
mkdir -p "$(dirname "${KUBECONFIG_PATH}")"
limactl shell "${VM_NAME}" sudo cat /etc/rancher/k3s/k3s.yaml > /tmp/k3s-raw.kubeconfig

# portForwards maps guest:6443 → host 127.0.0.1:6443, so no IP patching needed
KUBECONFIG=/tmp/k3s-raw.kubeconfig kubectl config rename-context default "${VM_NAME}"
cp /tmp/k3s-raw.kubeconfig "${KUBECONFIG_PATH}"
chmod 600 "${KUBECONFIG_PATH}"
rm -f /tmp/k3s-raw.kubeconfig

# ── Verify ─────────────────────────────────────────────────────────────────────
export KUBECONFIG="${KUBECONFIG_PATH}"
kubectl config use-context "${VM_NAME}"

echo ""
kubectl get nodes -o wide

echo ""
echo "======================================================"
echo " Lima K3s VM ready"
echo "======================================================"
echo ""
echo " Activate:"
echo "   export KUBECONFIG=${KUBECONFIG_PATH}"
echo ""
echo " Add to ~/.zshrc:"
echo "   alias use-k3s='export KUBECONFIG=${KUBECONFIG_PATH}'"
echo ""
echo " VM management:"
echo "   limactl stop  ${VM_NAME}   # pause"
echo "   limactl start ${VM_NAME}   # resume"
echo "   limactl shell ${VM_NAME}   # SSH in"
echo ""
echo " Next steps:"
echo "   export KUBECONFIG=${KUBECONFIG_PATH}"
echo "   ./scripts/setup-cilium.sh"
echo "   ./scripts/setup-metallb-lima.sh"
echo "   ./scripts/install-kamaji.sh"
echo "======================================================"
