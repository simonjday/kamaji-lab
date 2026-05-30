# Kamaji Platform Lab — Operations Guide

> Day 2 operations: worker recovery, cluster management, kubeconfig handling, teardown, and troubleshooting.

---

## Table of Contents

1. [Worker Node Management](#1-worker-node-management)
2. [Tenant Cluster Access](#2-tenant-cluster-access)
3. [Quota Management](#3-quota-management)
4. [Multiple Tenant Clusters](#4-multiple-tenant-clusters)
5. [Teardown and Rebuild](#5-teardown-and-rebuild)
6. [Troubleshooting](#6-troubleshooting)

---

## 1. Worker Node Management

### 1.1 After Docker Desktop or macOS restart

Worker containers survive restarts via `--restart unless-stopped` but lose runtime state (kube-proxy kubeconfig, Flannel subnet). Use the `recover-worker` shell helper:

```bash
# Recover tenant-demo worker
recover-worker tenant-demo

# Recover tenant-beta worker
recover-worker tenant-beta tenant-beta kamaji-worker-beta-01
```

This automatically:
- Recreates `/var/lib/kube-proxy/kubeconfig.conf`
- Fixes the kube-proxy conntrack configmap (`maxPerCore: 0`, `min: 0`)
- Deletes stuck pods to force a clean restart
- Waits for all pods to come back Running

> **Why this happens:** The `/var/lib/kube-proxy` directory wasn't persisted as a Docker volume in older worker setups. Workers created with `setup-worker-kind.sh` v2+ include `-v /var/lib/kube-proxy` and are less prone to this. If recovery fails, recreate the worker via `teardown.sh worker` + `setup-worker-kind.sh`.

### 1.2 Check worker status

```bash
# Quick overview of all workers
kamaji-status

# Detailed worker container state
docker ps --filter "name=kamaji-worker" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"

# Worker kubelet logs
docker exec kamaji-worker-01 journalctl -u kubelet -n 20 --no-pager
```

### 1.3 Add a worker

```bash
export KUBECONFIG=~/.kube/config
./scripts/setup-worker-kind.sh tenant-demo tenant-demo kamaji-worker-02
```

### 1.4 Drain and remove a worker

```bash
use-tenant tenant-demo

# Cordon and drain
kubectl drain worker-02 --ignore-daemonsets --delete-emptydir-data --force

# Remove from cluster
kubectl delete node worker-02

# Remove Docker container
./scripts/teardown.sh worker kamaji-worker-02
```

### 1.5 Worker restart policy

All workers are created with `--restart unless-stopped`. To apply this to an existing container:

```bash
docker update --restart unless-stopped kamaji-worker-01
docker update --restart unless-stopped kamaji-worker-beta-01
```

---

## 2. Tenant Cluster Access

### 2.1 Switch clusters

```bash
use-mgmt              # management cluster (kind-kamaji-mgmt)
use-tenant tenant-demo  # tenant cluster (starts port-forward on :7443)
use-tenant tenant-beta  # second tenant (port :7444 if configured)
```

`use-tenant` validates the kubeconfig on every call. If it detects corruption or a wrong server URL it regenerates automatically.

### 2.2 Regenerate tenant kubeconfig manually

```bash
export KUBECONFIG=~/.kube/config

kubectl get secret tenant-demo-admin-kubeconfig \
  -n tenant-demo -o jsonpath='{.data.admin\.conf}' | base64 -d \
  > ~/.kube/tenant-demo.kubeconfig

TCP_EP=$(kubectl get tcp tenant-demo -n tenant-demo \
  -o jsonpath='{.status.controlPlaneEndpoint}')

sed "s|https://${TCP_EP}|https://127.0.0.1:7443|g" \
  ~/.kube/tenant-demo.kubeconfig > ~/.kube/tenant-demo-local.kubeconfig
```

### 2.3 Merge all kubeconfigs into one file

```bash
KUBECONFIG=~/.kube/config:~/.kube/tenant-demo-local.kubeconfig \
  kubectl config view --flatten > /tmp/merged.kubeconfig

cp ~/.kube/config ~/.kube/config.bak
mv /tmp/merged.kubeconfig ~/.kube/config

kubectl config get-contexts
```

### 2.4 Scoped kubeconfig for a tenant user

```bash
use-tenant tenant-demo

kubectl create serviceaccount charlie -n team-beta-api
kubectl create rolebinding charlie-edit \
  --clusterrole=edit \
  --serviceaccount=team-beta-api:charlie \
  -n team-beta-api

TOKEN=$(kubectl create token charlie -n team-beta-api --duration=24h)
CA=$(kubectl config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
SERVER=$(kubectl config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.server}')

cat > ~/.kube/charlie-team-beta.kubeconfig << EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${CA}
    server: ${SERVER}
  name: tenant-demo
contexts:
- context:
    cluster: tenant-demo
    user: charlie
    namespace: team-beta-api
  name: charlie@team-beta
current-context: charlie@team-beta
users:
- name: charlie
  user:
    token: ${TOKEN}
EOF

KUBECONFIG=~/.kube/charlie-team-beta.kubeconfig kubectl get pods
```

### 2.5 Port-forward management

Port-forwards are started automatically by `use-tenant` but can die. Restart manually:

```bash
# Kill existing
lsof -ti:7443 | xargs kill -9 2>/dev/null || true

# Restart
export KUBECONFIG=~/.kube/config
kubectl port-forward svc/tenant-demo -n tenant-demo 7443:6443 &
```

---

## 3. Quota Management

### 3.1 View current quota usage

```bash
use-tenant tenant-demo

# Per-namespace quota usage
kubectl get resourcequota -A

# Tenant namespace count
kubectl get tenant team-alpha -o jsonpath='{.status.size}'
kubectl get tenant team-alpha -o jsonpath='{.status.namespaces}'
```

### 3.2 Patch tenant quota

```bash
kubectl patch tenant team-alpha --type=merge \
  -p '{"spec":{"namespaceOptions":{"quota":5}}}'

# Force reconciliation
kubectl rollout restart deployment/capsule-controller-manager -n capsule-system
kubectl rollout status deployment/capsule-controller-manager -n capsule-system
```

### 3.3 Trigger reconcile without restart

```bash
kubectl annotate tenant team-alpha \
  reconcile-trigger="$(date +%s)" --overwrite
```

### 3.4 Add a new tenant

```bash
kubectl apply -f - <<'EOF'
apiVersion: capsule.clastix.io/v1beta2
kind: Tenant
metadata:
  name: team-gamma
spec:
  owners:
    - name: charlie
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

kubectl create clusterrolebinding capsule-charlie-provisioner \
  --clusterrole=capsule-namespace-provisioner --user=charlie

kubectl rollout restart deployment/capsule-controller-manager -n capsule-system
kubectl get tenants
```

### 3.5 Exempting system namespaces from Capsule

Tools like ArgoCD and Prometheus create namespaces that don't match any tenant prefix. Capsule will block them unless exempted:

```bash
kubectl patch capsuleconfiguration default --type=merge -p '{
  "spec": {
    "protectedNamespaceRegex": "^(argocd|monitoring|cert-manager|capsule-system|kube-.*)$"
  }
}'
```

---

## 4. Multiple Tenant Clusters

### 4.1 Provision a second TCP

```bash
use-mgmt

kubectl create namespace tenant-beta

kubectl apply -f - <<'EOF'
apiVersion: kamaji.clastix.io/v1alpha1
kind: TenantControlPlane
metadata:
  name: tenant-beta
  namespace: tenant-beta
spec:
  dataStore: default
  controlPlane:
    deployment:
      replicas: 1
    service:
      serviceType: LoadBalancer
  kubernetes:
    version: v1.30.2
    kubelet:
      cgroupfs: systemd
  networkProfile:
    port: 6443
    certSANs:
      - "127.0.0.1"
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

kubectl get tcp -A -w
```

### 4.2 Connect to tenant-beta

```bash
kubectl get secret tenant-beta-admin-kubeconfig \
  -n tenant-beta -o jsonpath='{.data.admin\.conf}' | base64 -d \
  > ~/.kube/tenant-beta.kubeconfig

BETA_EP=$(kubectl get tcp tenant-beta -n tenant-beta \
  -o jsonpath='{.status.controlPlaneEndpoint}')

sed "s|https://${BETA_EP}|https://127.0.0.1:7444|g" \
  ~/.kube/tenant-beta.kubeconfig > ~/.kube/tenant-beta-local.kubeconfig

use-tenant tenant-beta tenant-beta 7444
```

### 4.3 Join a worker to tenant-beta

```bash
export KUBECONFIG=~/.kube/config
./scripts/setup-worker-kind.sh tenant-beta tenant-beta kamaji-worker-beta-01
```

### 4.4 Scale TCP control plane replicas

```bash
use-mgmt

# Scale to 2 replicas (HA control plane)
kubectl patch tcp tenant-demo -n tenant-demo --type=merge \
  -p '{"spec":{"controlPlane":{"deployment":{"replicas":2}}}}'

kubectl get pods -n tenant-demo -w

# Scale back to 1
kubectl patch tcp tenant-demo -n tenant-demo --type=merge \
  -p '{"spec":{"controlPlane":{"deployment":{"replicas":1}}}}'
```

---

## 5. Teardown and Rebuild

### 5.1 Full teardown

```bash
./scripts/teardown.sh
# Removes: kind cluster, all kamaji-worker-* containers, kubeconfigs
```

### 5.2 Partial teardown

```bash
./scripts/teardown.sh worker                    # remove default worker only
./scripts/teardown.sh worker kamaji-worker-02   # remove specific worker
./scripts/teardown.sh cluster                   # kind cluster only
./scripts/teardown.sh configs                   # kubeconfigs only
```

### 5.3 Full rebuild from scratch

```bash
./scripts/teardown.sh

./scripts/setup-kind-kamaji.sh
kind export kubeconfig --name kamaji-mgmt
export KUBECONFIG=~/.kube/config

kubectl create namespace tenant-demo
kubectl apply -f manifests/tenants/tenant-demo.yaml
kubectl get tcp -n tenant-demo -w

kubectl get secret tenant-demo-admin-kubeconfig \
  -n tenant-demo -o jsonpath='{.data.admin\.conf}' | base64 -d \
  > ~/.kube/tenant-demo.kubeconfig
sed 's|https://172.18.255.200:6443|https://127.0.0.1:7443|g' \
  ~/.kube/tenant-demo.kubeconfig > ~/.kube/tenant-demo-local.kubeconfig

./scripts/setup-worker-kind.sh tenant-demo tenant-demo
./scripts/setup-capsule.sh ~/.kube/tenant-demo-local.kubeconfig
./scripts/setup-kamaji-console.sh
```

---

## 6. Troubleshooting

### 6.1 kind context lost

```bash
kind export kubeconfig --name kamaji-mgmt
# or use-mgmt (auto-recovers)
```

### 6.2 Tenant kubeconfig points at wrong cluster

```bash
reset-tenant tenant-demo
use-tenant tenant-demo   # regenerates automatically
```

### 6.3 Pods stuck in Unknown after worker restart

```bash
use-tenant tenant-demo
recover-worker tenant-demo
```

### 6.4 konnectivity agent not starting

konnectivity depends on Flannel being healthy. If it's stuck:

```bash
use-tenant tenant-demo
kubectl delete pod -n kube-flannel --all
kubectl delete pod -n kube-system -l app=konnectivity-agent
sleep 10
kubectl get pods -A
```

### 6.5 Capsule blocking namespace creation

Check if the namespace matches the tenant prefix pattern:

```bash
# View tenant owner and prefix
kubectl get tenant team-alpha -o yaml | grep -A5 owners

# Check forceTenantPrefix
kubectl get capsuleconfiguration default \
  -o jsonpath='{.spec.forceTenantPrefix}'

# Exempt system namespaces
kubectl patch capsuleconfiguration default --type=merge -p '{
  "spec": {
    "protectedNamespaceRegex": "^(argocd|monitoring|cert-manager|capsule-system|kube-.*)$"
  }
}'
```

### 6.6 ArgoCD ApplicationSet CRD fails to install

```bash
kubectl apply \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/crds/applicationset-crd.yaml \
  --server-side --force-conflicts
```

### 6.7 Prometheus not scraping etcd

The etcd cert secret must be in the monitoring namespace (Prometheus can't mount cross-namespace secrets):

```bash
kubectl get secret etcd-certs -n kamaji-system -o yaml | \
  sed 's/namespace: kamaji-system/namespace: monitoring/' | \
  kubectl apply -f -

kubectl delete pod prometheus-mgmt-monitoring-kube-prome-prometheus-0 \
  -n monitoring
```

### 6.8 Port-forward dropped

```bash
# Kill all port-forwards
pkill -f "kubectl port-forward" 2>/dev/null || true

# Restart via helpers
use-mgmt
use-tenant tenant-demo
kamaji-ui
```
