#!/usr/bin/env bash
# install-kamaji.sh — Install Kamaji on the current kubeconfig context
# Compatible with: kind, Lima K3s, Rancher Desktop K3s
# Run AFTER: cert-manager and MetalLB are in place
# Usage: ./install-kamaji.sh
set -euo pipefail

CONTEXT=$(kubectl config current-context)
echo "==> Installing Kamaji"
echo "    Context: ${CONTEXT}"

# ── Helm repos ─────────────────────────────────────────────────────────────────
echo "==> Adding/updating Helm repos"
helm repo add clastix   https://clastix.github.io/charts   2>/dev/null || true
helm repo add jetstack  https://charts.jetstack.io          2>/dev/null || true
helm repo update

# ── cert-manager ───────────────────────────────────────────────────────────────
if kubectl get ns cert-manager &>/dev/null 2>&1; then
  echo "==> cert-manager already installed — skipping"
else
  echo "==> Installing cert-manager"
  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --set installCRDs=true \
    --wait
fi

# ── Kamaji ─────────────────────────────────────────────────────────────────────
EXTRA_FLAGS=""
# Drop resource requests for kind — not appropriate for production
if echo "${CONTEXT}" | grep -qi kind; then
  echo "==> kind context detected — disabling resource requests (lab mode)"
  EXTRA_FLAGS="--set resources=null"
fi

echo "==> Installing Kamaji Helm chart"
helm upgrade --install kamaji clastix/kamaji \
  --namespace kamaji-system \
  --create-namespace \
  --version 0.0.0+latest \
  ${EXTRA_FLAGS} \
  --wait

# ── Verify ─────────────────────────────────────────────────────────────────────
echo ""
echo "==> Verifying installation"
echo ""
echo "--- kamaji-system pods ---"
kubectl get pods -n kamaji-system

echo ""
echo "--- kamaji-etcd pods ---"
kubectl get pods -n kamaji-etcd

echo ""
echo "--- DataStore ---"
kubectl get datastore

echo ""
echo "--- Kamaji CRDs ---"
kubectl get crds | grep kamaji

echo ""
echo "==> Kamaji installed successfully on context: ${CONTEXT}"
echo ""
echo "==> To create your first TenantControlPlane:"
echo ""
cat <<'YAML'
kubectl create namespace tenant-demo
kubectl apply -f - <<'EOF'
apiVersion: kamaji.clastix.io/v1alpha1
kind: TenantControlPlane
metadata:
  name: tenant-demo
  namespace: tenant-demo
spec:
  dataStore: default
  controlPlane:
    deployment:
      replicas: 1
    service:
      serviceType: LoadBalancer
  kubernetes:
    version: v1.32.0
    kubelet:
      cgroupfs: systemd
  networkProfile:
    port: 6443
  addons:
    coreDNS: {}
    kubeProxy: {}
    konnectivity:
      server:
        port: 8132
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
EOF

# Watch it come up
kubectl get tcp -n tenant-demo -w
YAML
