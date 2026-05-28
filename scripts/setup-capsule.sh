#!/usr/bin/env bash
# setup-capsule.sh — Install Capsule on a Kamaji TenantControlPlane
#
# Usage: ./scripts/setup-capsule.sh [tenant-kubeconfig]
#
# Tested on: Capsule v0.13.0, K8s v1.32, Kamaji tenant cluster
#
# What this does:
#   1. Installs cert-manager on the tenant cluster (Capsule webhook requires it)
#   2. Installs Capsule
#   3. Patches CapsuleConfiguration to enforce namespace quota and prefix
#   4. Creates a demo Tenant with owner RBAC

set -euo pipefail

TENANT_KUBECONFIG="${1:-${HOME}/.kube/tenant-demo-local.kubeconfig}"

if [ ! -f "${TENANT_KUBECONFIG}" ]; then
  echo "ERROR: Tenant kubeconfig not found: ${TENANT_KUBECONFIG}"
  echo "       Run: ./scripts/get-tenant-kubeconfig.sh <tcp-name> <namespace>"
  exit 1
fi

export KUBECONFIG="${TENANT_KUBECONFIG}"

echo "==> Installing Capsule on: $(kubectl config current-context)"
echo ""

# ── Preflight: verify ClusterIP routing is working ────────────────────────────
echo "==> Checking API server reachability (10.96.0.1)"
if ! kubectl get namespaces &>/dev/null; then
  echo "ERROR: Cannot reach API server"
  echo "       Run: use-tenant <tcp-name>"
  exit 1
fi

# ── Step 1: cert-manager ──────────────────────────────────────────────────────
if kubectl get ns cert-manager &>/dev/null 2>&1; then
  echo "==> cert-manager already installed — skipping"
else
  echo "==> Step 1/3: Installing cert-manager (required by Capsule webhook)"
  helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
  helm repo update jetstack

  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --set installCRDs=true \
    --wait

  echo "==> cert-manager ready"
  kubectl get pods -n cert-manager
fi

echo ""

# ── Step 2: Capsule ───────────────────────────────────────────────────────────
echo "==> Step 2/3: Installing Capsule v0.13.0"
helm repo add projectcapsule https://projectcapsule.github.io/charts 2>/dev/null || true
helm repo update projectcapsule

helm install capsule projectcapsule/capsule \
  --namespace capsule-system \
  --create-namespace \
  --wait

kubectl get pods -n capsule-system
echo ""

# ── Step 3: Configure Capsule ─────────────────────────────────────────────────
echo "==> Step 3/3: Configuring Capsule"

# Enable forceTenantPrefix — required for namespace quota enforcement
# Without this, quotas are not enforced by the admission webhook
kubectl patch capsuleconfiguration default --type=merge -p '{
  "spec": {
    "forceTenantPrefix": true
  }
}'

echo "==> forceTenantPrefix enabled (namespaces must be prefixed with tenant name)"

# ── Create demo Tenant ────────────────────────────────────────────────────────
echo ""
echo "==> Creating demo Tenant: team-alpha (owner: alice)"

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
          limits.cpu: "8"
          limits.memory: 16Gi
          pods: "20"
EOF

# Grant alice namespace provisioner role
# NOTE: Capsule watches for group 'projectcapsule.dev' by default (not 'capsule.clastix.io')
# Users must pass --as-group=projectcapsule.dev for Capsule to intercept their requests
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: capsule-alice-provisioner
subjects:
- kind: User
  name: alice
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: capsule-namespace-provisioner
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: capsule-alice-deleter
subjects:
- kind: User
  name: alice
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: capsule-namespace-deleter
  apiGroup: rbac.authorization.k8s.io
EOF

echo ""
echo "======================================================"
echo " Capsule installed and configured"
echo "======================================================"
echo ""
kubectl get tenants
echo ""
echo " Demo commands:"
echo ""
echo " Create namespace as alice (must use group: projectcapsule.dev):"
echo "   kubectl --as=alice --as-group=projectcapsule.dev create namespace team-alpha-frontend"
echo "   kubectl --as=alice --as-group=projectcapsule.dev create namespace team-alpha-backend"
echo "   kubectl --as=alice --as-group=projectcapsule.dev create namespace team-alpha-data"
echo ""
echo " 4th namespace blocked by quota:"
echo "   kubectl --as=alice --as-group=projectcapsule.dev create namespace team-alpha-overflow"
echo "   # Error: Cannot exceed Namespace quota"
echo ""
echo " View tenant status:"
echo "   kubectl get tenant team-alpha -o jsonpath='{.status}' | jq ."
echo "======================================================"
