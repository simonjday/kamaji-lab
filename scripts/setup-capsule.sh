#!/usr/bin/env bash
# setup-capsule.sh — Install Capsule on a Kamaji TenantControlPlane
#
# Tested on: Capsule v0.13.0, K8s v1.30.2
#
# Usage: ./scripts/setup-capsule.sh [tenant-kubeconfig]

set -euo pipefail

TENANT_KUBECONFIG="${1:-${HOME}/.kube/tenant-demo-local.kubeconfig}"

if [ ! -f "${TENANT_KUBECONFIG}" ]; then
  echo "ERROR: Tenant kubeconfig not found: ${TENANT_KUBECONFIG}"
  exit 1
fi

export KUBECONFIG="${TENANT_KUBECONFIG}"

echo "==> Installing Capsule on: $(kubectl config current-context)"

# ── cert-manager ───────────────────────────────────────────────────────────────
if kubectl get ns cert-manager &>/dev/null 2>&1; then
  echo "==> cert-manager already installed"
else
  echo "==> Installing cert-manager"
  helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
  helm repo update jetstack
  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --set installCRDs=true \
    --wait
fi

# ── Capsule ───────────────────────────────────────────────────────────────────
echo "==> Installing Capsule"
helm repo add projectcapsule https://projectcapsule.github.io/charts 2>/dev/null || true
helm repo update projectcapsule

helm install capsule projectcapsule/capsule \
  --namespace capsule-system \
  --create-namespace \
  --wait 2>/dev/null || true

# Helm may report failure due to --wait timeout — check pods directly
sleep 5
if ! kubectl get pods -n capsule-system 2>/dev/null | grep -q Running; then
  echo "ERROR: Capsule pods not running"
  kubectl get pods -n capsule-system
  exit 1
fi

echo "==> Capsule running"

# ── Configure ─────────────────────────────────────────────────────────────────
echo "==> Enabling forceTenantPrefix"
kubectl patch capsuleconfiguration default --type=merge \
  -p '{"spec":{"forceTenantPrefix":true}}'

# ── Demo tenants ──────────────────────────────────────────────────────────────
echo "==> Creating demo tenants: team-alpha (alice) and team-beta (bob)"

kubectl apply -f - <<'EOF'
apiVersion: capsule.clastix.io/v1beta2
kind: Tenant
metadata:
  name: team-alpha
spec:
  owners:
    - name: alice
      kind: User
  namespaceOptions:
    quota: 3
  resourceQuotas:
    scope: Tenant
    items:
      - hard:
          requests.cpu: "4"
          requests.memory: 8Gi
          pods: "20"
---
apiVersion: capsule.clastix.io/v1beta2
kind: Tenant
metadata:
  name: team-beta
spec:
  owners:
    - name: bob
      kind: User
  namespaceOptions:
    quota: 3
  resourceQuotas:
    scope: Tenant
    items:
      - hard:
          requests.cpu: "2"
          requests.memory: 4Gi
          pods: "10"
EOF

# Grant owner rights
kubectl create clusterrolebinding capsule-alice-provisioner \
  --clusterrole=capsule-namespace-provisioner --user=alice 2>/dev/null || true
kubectl create clusterrolebinding capsule-alice-deleter \
  --clusterrole=capsule-namespace-deleter --user=alice 2>/dev/null || true
kubectl create clusterrolebinding capsule-bob-provisioner \
  --clusterrole=capsule-namespace-provisioner --user=bob 2>/dev/null || true
kubectl create clusterrolebinding capsule-bob-deleter \
  --clusterrole=capsule-namespace-deleter --user=bob 2>/dev/null || true

echo ""
echo "======================================================"
echo " Capsule installed"
echo "======================================================"
kubectl get tenants
echo ""
echo " Demo:"
echo "   kubectl --as=alice --as-group=projectcapsule.dev create namespace team-alpha-frontend"
echo "   kubectl --as=alice --as-group=projectcapsule.dev create namespace team-alpha-backend"
echo "   kubectl --as=alice --as-group=projectcapsule.dev create namespace team-alpha-data"
echo "   kubectl --as=alice --as-group=projectcapsule.dev create namespace team-alpha-overflow"
echo "   # Error: Cannot exceed Namespace quota"
echo "======================================================"
