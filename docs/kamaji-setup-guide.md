# Kamaji Platform Lab — Setup Guide

> Installation reference for running a multi-tenant Kubernetes platform using Kamaji, Capsule, and Kamaji Console on macOS Apple Silicon using kind.

---

## Table of Contents

1. [What is Kamaji](#1-what-is-kamaji)
2. [Architecture](#2-architecture)
3. [Prerequisites](#3-prerequisites)
4. [Management Cluster Setup](#4-management-cluster-setup)
5. [Creating a Tenant Control Plane](#5-creating-a-tenant-control-plane)
6. [Joining Worker Nodes](#6-joining-worker-nodes)
7. [Capsule Multi-Tenancy](#7-capsule-multi-tenancy)
8. [Kamaji Console](#8-kamaji-console)
9. [Shell Helpers Reference](#9-shell-helpers-reference)
10. [Known Issues](#10-known-issues)

---

## 1. What is Kamaji

Kamaji is a Kubernetes operator that runs Tenant Control Planes (TCPs) as pods inside a management cluster. Instead of provisioning a full VM per cluster, the control plane components (API server, controller manager, scheduler, konnectivity) run as containers. Worker nodes join the TCP just like a normal Kubernetes cluster.

| Term | Meaning |
|---|---|
| Management cluster | The K8s cluster that runs Kamaji and hosts TCP pods |
| TenantControlPlane (TCP) | A full K8s control plane running as pods |
| DataStore | The etcd backing store for TCPs (shared or dedicated) |
| Worker node | A Docker container that joins a TCP via kubelet |
| Konnectivity | Tunnel between TCP API server and worker kubelets |

---

## 2. Architecture

```
macOS M3
  └── Docker Desktop
        ├── kind cluster: kamaji-mgmt (K8s v1.34)
        │     ├── cert-manager
        │     ├── MetalLB (pool: 172.18.255.200-250)
        │     ├── Gateway API CRDs
        │     ├── Kamaji Operator
        │     ├── kamaji-etcd (3-node StatefulSet)
        │     └── Kamaji Console
        │
        └── Docker container: kamaji-worker-01
              ├── kubelet v1.30.2 → TenantControlPlane tenant-demo
              ├── Flannel CNI
              ├── CoreDNS
              ├── konnectivity-agent
              └── kube-proxy

Mac host
  └── kubectl port-forward :7443 → 172.18.255.200:6443
```

**Why kind?** Runs K8s inside Docker — fully self-contained, no VMs. Docker network provides direct MetalLB IP routing between containers.

**Why Docker container workers?** Same Docker `kind` network as the management cluster. MetalLB IPs (`172.18.255.x`) are directly reachable — no VM networking required.

**Why port-forward for kubectl?** MetalLB IPs are inside Docker's network and not routable from the Mac host.

---

## 3. Prerequisites

### 3.1 Install tools

```bash
brew install kind helm kubectl
brew install --cask docker
```

| Tool | Min version |
|---|---|
| Docker Desktop | 4.x |
| kind | v0.20+ |
| helm | v3.x |
| kubectl | v1.30+ |

### 3.2 Verify

```bash
docker info
kind version
helm version
kubectl version --client
```

### 3.3 Add Helm repos

```bash
helm repo add clastix https://clastix.github.io/charts
helm repo add jetstack https://charts.jetstack.io
helm repo add projectcapsule https://projectcapsule.github.io/charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

### 3.4 Clone and setup

```bash
git clone https://github.com/simonjday/kamaji-lab
cd kamaji-lab
chmod +x scripts/*.sh

# Source shell helpers
echo 'source "$(pwd)/scripts/shell-helpers.zsh"' >> ~/.zshrc
source ~/.zshrc
```

### 3.5 Docker Desktop settings

- **Resources → CPUs:** 4+
- **Resources → Memory:** 8GB+
- **Features in development:** Enable VirtioFS

---

## 4. Management Cluster Setup

```bash
./scripts/setup-kind-kamaji.sh
kind export kubeconfig --name kamaji-mgmt
export KUBECONFIG=~/.kube/config
kubectl get nodes
```

### Manual steps

**4.1 kind cluster:**

```bash
kind create cluster --name kamaji-mgmt
kubectl config use-context kind-kamaji-mgmt
```

**4.2 MetalLB:**

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.3/config/manifests/metallb-native.yaml
kubectl rollout status daemonset/speaker -n metallb-system --timeout=120s

kubectl apply -f - <<'EOF'
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
    - 172.18.255.200-172.18.255.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-l2
  namespace: metallb-system
EOF
```

> The pool `172.18.255.x` assumes Docker's default `kind` network. Verify: `docker network inspect kind | grep Gateway`. The setup script auto-detects the correct subnet.

**4.3 cert-manager:**

```bash
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true \
  --wait
```

**4.4 Gateway API CRDs** (required by latest Kamaji):

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/experimental-install.yaml
```

**4.5 Kamaji:**

```bash
helm install kamaji clastix/kamaji \
  --namespace kamaji-system \
  --create-namespace \
  --wait

kubectl get pods -n kamaji-system
kubectl get datastore
```

---

## 5. Creating a Tenant Control Plane

### 5.1 Apply TCP manifest

```bash
kubectl create namespace tenant-demo
kubectl apply -f manifests/tenants/tenant-demo.yaml
kubectl get tcp -n tenant-demo -w
# NAME          VERSION   STATUS   CONTROL-PLANE ENDPOINT        AGE
# tenant-demo   v1.30.2   Ready    172.18.255.200:6443           21s
```

> **K8s version — management vs tenant:**
> These intentionally differ. The management cluster (v1.34) runs Kamaji and TCP pods. The TCP version (v1.30.2) is what workers join and users interact with. Kamaji validates TCP version ≤ management version. Attempting v1.32+ is rejected by the admission webhook.

### 5.2 Extract tenant kubeconfig

```bash
export KUBECONFIG=~/.kube/config

kubectl get secret tenant-demo-admin-kubeconfig \
  -n tenant-demo -o jsonpath='{.data.admin\.conf}' | base64 -d \
  > ~/.kube/tenant-demo.kubeconfig

sed 's|https://172.18.255.200:6443|https://127.0.0.1:7443|g' \
  ~/.kube/tenant-demo.kubeconfig > ~/.kube/tenant-demo-local.kubeconfig
```

### 5.3 Connect to the tenant cluster

```bash
use-tenant tenant-demo
kubectl get namespaces
```

---

## 6. Joining Worker Nodes

```bash
export KUBECONFIG=~/.kube/config
./scripts/setup-worker-kind.sh tenant-demo tenant-demo
```

### What the script does

1. Creates a Docker container (`kindest/node:v1.30.2`) in the `kind` network with `--restart unless-stopped`
2. Installs CNI plugins v1.5.1 (arm64/amd64 auto-detected)
3. Copies TCP CA cert into `/etc/kubernetes/pki/ca.crt`
4. Creates bootstrap token in the tenant cluster
5. Writes `/etc/kubernetes/bootstrap-kubelet.conf` with the token
6. Creates `/var/lib/kubelet/config.yaml` (required for kubelet to start)
7. Sets `KUBELET_EXTRA_ARGS=--fail-swap-on=false` (kindest/node has swap enabled)
8. Fixes kube-proxy conntrack configmap and kubeconfig
9. Installs Flannel CNI

### Adding additional workers

```bash
./scripts/setup-worker-kind.sh tenant-demo tenant-demo kamaji-worker-02
```

Each worker gets its own bootstrap token. The hostname in Kubernetes is derived from the container name (`kamaji-worker-02` → `worker-02`).

### Removing a worker

```bash
export KUBECONFIG=~/.kube/tenant-demo-local.kubeconfig
kubectl drain worker-02 --ignore-daemonsets --delete-emptydir-data
kubectl delete node worker-02

./scripts/teardown.sh worker kamaji-worker-02
```

---

## 7. Capsule Multi-Tenancy

### 7.1 Install

```bash
./scripts/setup-capsule.sh ~/.kube/tenant-demo-local.kubeconfig
```

This installs cert-manager (if not present), Capsule, enables `forceTenantPrefix`, creates `team-alpha` (alice) and `team-beta` (bob), and restarts the controller to reconcile namespace counts.

### 7.2 Quota reconciliation

Capsule v0.13.0 has a reconciliation lag — `status.size` may not update immediately after namespace creation. The webhook reads `status.size` for quota checks. Always restart the controller after install or quota changes:

```bash
kubectl rollout restart deployment/capsule-controller-manager -n capsule-system
```

To trigger reconcile without a full restart:

```bash
kubectl annotate tenant team-alpha reconcile-trigger="$(date +%s)" --overwrite
```

### 7.3 Patching tenant quotas

```bash
kubectl patch tenant team-alpha --type=merge \
  -p '{"spec":{"namespaceOptions":{"quota":5}}}'

# Force immediate reconciliation
kubectl rollout restart deployment/capsule-controller-manager -n capsule-system
```

### 7.4 Demo — namespace quota and isolation

```bash
use-tenant tenant-demo

# Alice creates 3 namespaces (quota limit)
kubectl --as=alice --as-group=projectcapsule.dev create namespace team-alpha-frontend
kubectl --as=alice --as-group=projectcapsule.dev create namespace team-alpha-backend
kubectl --as=alice --as-group=projectcapsule.dev create namespace team-alpha-data

# 4th blocked by quota
kubectl --as=alice --as-group=projectcapsule.dev create namespace team-alpha-overflow
# Error: Cannot exceed Namespace quota

# Wrong prefix blocked
kubectl --as=alice --as-group=projectcapsule.dev create namespace frontend
# Error: The Namespace name must start with 'team-alpha-'

# Bob cannot access Alice's namespaces
kubectl --as=bob --as-group=projectcapsule.dev get pods -n team-alpha-frontend
# Error: Forbidden
```

### 7.5 Exempting system namespaces

Some tools (ArgoCD, Prometheus) need namespaces that don't match any tenant prefix. Exempt them via `protectedNamespaceRegex`:

```bash
kubectl patch capsuleconfiguration default --type=merge -p '{
  "spec": {
    "protectedNamespaceRegex": "^(argocd|monitoring|cert-manager|capsule-system|kube-.*)$"
  }
}'
```

---

## 8. Kamaji Console

```bash
export KUBECONFIG=~/.kube/config
./scripts/setup-kamaji-console.sh

# Start
kubectl port-forward -n kamaji-system svc/kamaji-console 8080:80 &
open http://localhost:8080/ui
# Login: admin@lab.local / admin123
```

> **Gotchas:**
> - URL path is `/ui` — root returns 404
> - Secret key must be `JWT_SECRET` not `NEXTAUTH_SECRET`
> - Password must be alphanumeric — special characters cause silent auth failure
> - `credentialsSecret.generate=true` is broken — always create the secret manually

---

## 9. Shell Helpers Reference

Source `scripts/shell-helpers.zsh` in `~/.zshrc`.

| Command | Cluster | Description |
|---|---|---|
| `use-mgmt` | Management | Switch context, auto-recover kind context if lost |
| `use-tenant <tcp>` | Tenant | Switch context, validate/regenerate kubeconfig, start port-forward |
| `kamaji-status` | Both | TCP list, management pods, worker container status |
| `kamaji-ui` | Management | Port-forward + open Kamaji Console |
| `recover-worker <tcp>` | Tenant | Rebuild kube-proxy kubeconfig and fix pods after restart |
| `reset-tenant <tcp>` | — | Delete cached kubeconfigs and kill port-forward |

---

## 10. Known Issues

| Issue | Cause | Fix |
|---|---|---|
| TCP version > management cluster version rejected | By design — Kamaji validates TCP ≤ management version | Use `v1.30.2` with kind v1.34 |
| Kamaji crashes: `TLSRoute CRD not found` | Latest Kamaji watches Gateway API resources | Install experimental Gateway API CRDs before Kamaji |
| MetalLB IP pool shows `1172.x.x.x` | `docker network inspect` returns IPv6+IPv4 concatenated | Script uses subnet detection — see `setup-kind-kamaji.sh` |
| MetalLB IP not reachable from Mac | kind Docker network not routed to Mac host | Use `kubectl port-forward` for all tenant access |
| kubelet crashes: `bootstrap-kubelet.conf not found` | kubeadm writes `kubelet.conf` but kubelet needs bootstrap config | Script writes `bootstrap-kubelet.conf` with token |
| kubelet crashes: `config.yaml not found` | kindest/node requires `/var/lib/kubelet/config.yaml` pre-existing | Script creates minimal `config.yaml` before kubelet start |
| kubelet crashes: swap enabled | `kindest/node` has swap enabled | `KUBELET_EXTRA_ARGS=--fail-swap-on=false` in `/etc/default/kubelet` |
| kube-proxy crashes: `nf_conntrack_max permission denied` | Container lacks sysctl privileges | Set `conntrack.maxPerCore: 0` and `min: 0` in kube-proxy ConfigMap |
| kube-proxy crashes: `kubeconfig.conf not found` | `/var/lib/kube-proxy/kubeconfig.conf` lost on container restart | Run `recover-worker <tcp>` or script recreates it |
| Flannel crashes: `bridge plugin not found` | `kindest/node` missing CNI plugins | Script installs CNI plugins v1.5.1 |
| Worker loses kube-proxy kubeconfig on restart | `/var/lib/kube-proxy` not persisted in older setups | Workers created with v2+ script include `-v /var/lib/kube-proxy`. Run `recover-worker` |
| kind context lost after teardown | `kind delete cluster` removes context from kubeconfig | `kind export kubeconfig --name kamaji-mgmt` or `use-mgmt` auto-recovers |
| Tenant kubeconfig points at wrong cluster | Context merging corrupts server URL | `use-tenant` validates and regenerates automatically |
| Capsule Helm shows `failed` | `--wait` timeout | Check pods directly — if Running, install succeeded |
| Capsule quota not enforced | `forceTenantPrefix` not set or `status.size` stale | Enable flag + restart controller |
| Capsule blocks system namespace creation | All namespaces must match a tenant prefix by default | Set `protectedNamespaceRegex` to exempt system namespaces |
| ApplicationSet CRD annotation too large | Kubernetes annotation size limit (262144 bytes) | Use `--server-side --force-conflicts` |
| Kamaji Console 404 on root | Console serves at `/ui` not `/` | Use `http://localhost:8080/ui` |
