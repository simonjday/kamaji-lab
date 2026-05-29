#!/usr/bin/env bash
# setup-kind-kamaji.sh — Create kind management cluster and install Kamaji
#
# Tested on: macOS M3, Docker Desktop, kind v0.20+
#
# What this installs:
#   - kind cluster: kamaji-mgmt (K8s v1.34)
#   - MetalLB with pool 172.18.255.200-250
#   - cert-manager (required by Kamaji webhooks)
#   - Gateway API experimental CRDs (required by latest Kamaji)
#   - Kamaji operator + kamaji-etcd (3-node)
#
# Usage: ./scripts/setup-kind-kamaji.sh

set -euo pipefail

CLUSTER_NAME="kamaji-mgmt"
KUBECONFIG_PATH="${HOME}/.kube/k3s-kamaji.kubeconfig"
METALLB_VERSION="v0.15.3"
GATEWAY_API_VERSION="v1.2.1"

echo "==> Setting up Kamaji management cluster on kind"
echo ""

# ── Preflight ──────────────────────────────────────────────────────────────────
for cmd in kind helm kubectl docker; do
  if ! command -v "${cmd}" &>/dev/null; then
    echo "ERROR: ${cmd} not found. Install with: brew install ${cmd}"
    exit 1
  fi
done

if ! docker info &>/dev/null; then
  echo "ERROR: Docker is not running. Start Docker Desktop."
  exit 1
fi

# ── Step 1: kind cluster ───────────────────────────────────────────────────────
echo "==> Step 1/5: Creating kind cluster: ${CLUSTER_NAME}"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "==> Cluster '${CLUSTER_NAME}' already exists — skipping"
else
  kind create cluster --name "${CLUSTER_NAME}"
fi

kubectl config use-context "kind-${CLUSTER_NAME}"

echo "==> Waiting for node Ready"
kubectl wait --for=condition=Ready node --all --timeout=120s
kubectl get nodes

# ── Step 2: MetalLB ───────────────────────────────────────────────────────────
echo ""
echo "==> Step 2/5: Installing MetalLB ${METALLB_VERSION}"

kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"
kubectl rollout status daemonset/speaker -n metallb-system --timeout=120s

# Detect Docker kind network gateway
DOCKER_GATEWAY=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' \
  | grep -oE '([0-9]+\.){3}[0-9]+' | head -1)
NET_PREFIX=$(echo "${DOCKER_GATEWAY}" | cut -d. -f1-2)

echo "==> Docker gateway: ${DOCKER_GATEWAY}"
echo "==> MetalLB pool: ${NET_PREFIX}.255.200-${NET_PREFIX}.255.250"

kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
    - ${NET_PREFIX}.255.200-${NET_PREFIX}.255.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-l2
  namespace: metallb-system
EOF

# ── Step 3: cert-manager ──────────────────────────────────────────────────────
echo ""
echo "==> Step 3/5: Installing cert-manager"

helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
helm repo update jetstack

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true \
  --wait

# ── Step 4: Gateway API CRDs ──────────────────────────────────────────────────
echo ""
echo "==> Step 4/5: Installing Gateway API CRDs (required by Kamaji)"

kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml"
sleep 5

# ── Step 5: Kamaji ────────────────────────────────────────────────────────────
echo ""
echo "==> Step 5/5: Installing Kamaji"

helm repo add clastix https://clastix.github.io/charts 2>/dev/null || true
helm repo update clastix

helm upgrade --install kamaji clastix/kamaji \
  --namespace kamaji-system \
  --create-namespace \
  --wait

# ── Verify ─────────────────────────────────────────────────────────────────────
echo ""
echo "==> Verifying installation"
echo ""
echo "--- kamaji-system pods ---"
kubectl get pods -n kamaji-system
echo ""
echo "--- DataStore ---"
kubectl get datastore
echo ""

echo "======================================================"
echo " Kamaji management cluster ready"
echo "======================================================"
echo ""
echo " Context: kind-${CLUSTER_NAME}"
echo " Next steps:"
echo "   kubectl create namespace tenant-demo"
echo "   kubectl apply -f manifests/tenants/tenant-demo.yaml"
echo "   kubectl get tcp -n tenant-demo -w"
echo ""
echo " Then join a worker:"
echo "   ./scripts/setup-worker-kind.sh tenant-demo tenant-demo"
echo "======================================================"
