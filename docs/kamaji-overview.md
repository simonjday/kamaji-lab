# Kamaji Platform Engineering Lab — Kind Edition

> A practitioner's guide to running a multi-tenant Kubernetes platform using Kamaji, Capsule, and Kamaji Console on macOS — fully validated on Apple Silicon (M3) using kind.

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
9. [Shell Helpers](#9-shell-helpers)
10. [Known Issues](#10-known-issues)

---

## 1. What is Kamaji

Kamaji is a Kubernetes operator that runs Tenant Control Planes (TCPs) as pods inside a management cluster. Instead of provisioning a full VM per cluster, the control plane components (API server, controller manager, scheduler, konnectivity) run as containers. Worker nodes join the TCP just like a normal kubeadm cluster.

**Key concepts:**

| Term | Meaning |
|---|---|
| Management cluster | The K8s cluster that runs Kamaji and hosts TCP pods |
| TenantControlPlane (TCP) | A full K8s control plane running as pods |
| DataStore | The etcd backing store for TCPs (shared or dedicated) |
| Worker node | A real node that joins a TCP via kubelet |
| Konnectivity | Tunnel between TCP API server and worker kubelets |

---

## 2. Architecture

```
macOS M3
  └── Docker Desktop
        └── kind cluster: kamaji-mgmt (K8s v1.34)
              ├── cert-manager
              ├── MetalLB (pool: 172.18.255.200-250)
              ├── Gateway API CRDs (required by Kamaji)
              ├── Kamaji Operator
              ├── kamaji-etcd (3-node StatefulSet)
              ├── Kamaji Console (web UI)
              └── TenantControlPlane: tenant-demo (v1.30.2)
                    LoadBalancer IP: 172.18.255.200:6443

        └── Docker container: kamaji-worker-01
              ├── kubelet v1.30.2 (joined to tenant-demo)
              ├── Flannel CNI
              ├── CoreDNS
              ├── konnectivity-agent
              └── kube-proxy

Mac host
  └── kubectl port-forward :7443 → 172.18.255.200:6443 (tenant access)
```

**Why kind for the management cluster?**
Kind runs K8s inside Docker containers — fully self-contained, no VMs needed, Docker network provides direct MetalLB IP routing between containers.

**Why a Docker container for the worker?**
Worker containers run in the same Docker `kind` network as the management cluster. MetalLB IPs (`172.18.255.x`) are directly reachable from within the Docker network — no port-forwarding or VM networking required.

**Why port-forward for kubectl access?**
MetalLB IPs are inside Docker's network and not routable from the Mac host. A `kubectl port-forward` on the management cluster proxies TCP traffic from `127.0.0.1:7443` to the tenant API server.

---

## 3. Prerequisites

### 3.1 Install tools

```bash
brew install kind helm kubectl
brew install --cask docker   # Docker Desktop
```

| Tool | Min version | Install |
|---|---|---|
| Docker Desktop | 4.x | `brew install --cask docker` |
| kind | v0.20+ | `brew install kind` |
| helm | v3.x | `brew install helm` |
| kubectl | v1.30+ | `brew install kubectl` |

### 3.2 Verify

```bash
docker info              # Docker must be running
kind version             # v0.20+
helm version             # v3.x
kubectl version --client # v1.30+
```

### 3.3 Add Helm repos

```bash
helm repo add clastix https://clastix.github.io/charts
helm repo add jetstack https://charts.jetstack.io
helm repo add projectcapsule https://projectcapsule.github.io/charts
helm repo update
```

### 3.4 Clone the lab repo

```bash
git clone https://github.com/simonjday/kamaji-lab
cd kamaji-lab
chmod +x scripts/*.sh
```

### 3.5 Docker Desktop settings (macOS)

For best performance on Apple Silicon:

- **Resources → CPUs:** 4+
- **Resources → Memory:** 8GB+
- **Features in development:** Enable VirtioFS for faster file sharing

---

> **One-liner setup** — runs everything from scratch:
> ```bash
> ./scripts/setup-kind-kamaji.sh && >   kubectl apply -f manifests/tenants/tenant-demo.yaml && >   ./scripts/setup-worker-kind.sh tenant-demo tenant-demo && >   ./scripts/setup-capsule.sh && >   ./scripts/setup-kamaji-console.sh
> ```

---

## 4. Management Cluster Setup

Run the automated script:

```bash
cd /path/to/kamaji-lab
./scripts/setup-kind-kamaji.sh
```

Or follow the manual steps below.

### 4.1 Create kind cluster

```bash
kind create cluster --name kamaji-mgmt
kubectl config use-context kind-kamaji-mgmt
kubectl get nodes
# NAME                        STATUS   ROLES           AGE   VERSION
# kamaji-mgmt-control-plane   Ready    control-plane   30s   v1.34.0
```

### 4.2 MetalLB

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

> **Note:** The pool `172.18.255.x` is in Docker's default `kind` network (`172.18.0.0/16`). Verify your Docker network: `docker network inspect kind | grep Gateway`. Adjust if different.

### 4.3 cert-manager

Required by Kamaji for webhook TLS certificates.

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true \
  --wait
```

### 4.4 Gateway API CRDs

Required by the latest Kamaji operator (watches `TLSRoute` resources).

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/experimental-install.yaml
```

### 4.5 Kamaji

```bash
helm repo add clastix https://clastix.github.io/charts
helm repo update

helm install kamaji clastix/kamaji \
  --namespace kamaji-system \
  --create-namespace \
  --wait

kubectl get pods -n kamaji-system
# NAME                     READY   STATUS    RESTARTS   AGE
# etcd-0                   1/1     Running   0          30s
# etcd-1                   1/1     Running   0          25s
# etcd-2                   1/1     Running   0          20s
# kamaji-xxx               1/1     Running   0          30s
```

### 4.6 Verify DataStore

```bash
kubectl get datastore
# NAME      DRIVER   READY   AGE
# default   etcd     true    1m
```

---

## 5. Creating a Tenant Control Plane

### 5.1 Apply TCP manifest

```bash
kubectl create namespace tenant-demo

kubectl apply -f manifests/tenants/tenant-demo.yaml

kubectl get tcp -n tenant-demo -w
# NAME          VERSION   STATUS   CONTROL-PLANE ENDPOINT   KUBECONFIG                     DATASTORE   AGE
# tenant-demo   v1.30.2   Ready    172.18.255.200:6443      tenant-demo-admin-kubeconfig   default     19s
```

> **Kubernetes version constraint:** Kamaji validates that TCP versions don't exceed the management cluster version. Use `v1.30.2` with a kind v1.34 management cluster.

### 5.2 Extract kubeconfig and connect

```bash
# Extract the admin kubeconfig from the TCP secret
kubectl get secret tenant-demo-admin-kubeconfig \
  -n tenant-demo -o jsonpath='{.data.admin\.conf}' | base64 -d \
  > ~/.kube/tenant-demo.kubeconfig

# MetalLB IP is not routable from Mac — patch to use port-forward
sed 's|https://172.18.255.200:6443|https://127.0.0.1:7443|g' \
  ~/.kube/tenant-demo.kubeconfig > ~/.kube/tenant-demo-local.kubeconfig

# Start port-forward (keep running)
kubectl port-forward svc/tenant-demo -n tenant-demo 7443:6443 &
sleep 2

# Connect to tenant cluster
export KUBECONFIG=~/.kube/tenant-demo-local.kubeconfig
kubectl get namespaces
```

---

## 6. Joining Worker Nodes

Worker nodes are Docker containers running the `kindest/node` image in the same `kind` Docker network. This gives direct network access to the MetalLB IP without any bridging or port-forwarding.

Run the automated script:

```bash
export KUBECONFIG=~/.kube/config
./scripts/setup-worker-kind.sh tenant-demo tenant-demo
```

Or follow the manual steps below.

### 6.1 Create worker container

```bash
docker run -d \
  --name kamaji-worker-01 \
  --hostname worker-01 \
  --network kind \
  --privileged \
  --tmpfs /tmp \
  --tmpfs /run \
  -v /var/lib/containerd \
  -v /var/lib/kubelet \
  -v /etc/kubernetes \
  kindest/node:v1.30.2

WORKER_IP=$(docker inspect kamaji-worker-01 \
  -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
echo "Worker IP: ${WORKER_IP}"

# Verify connectivity to TCP
docker exec kamaji-worker-01 curl -sk \
  https://172.18.255.200:6443/version | grep gitVersion
```

### 6.2 Install CNI plugins

The `kindest/node` image doesn't include all CNI plugins needed by Flannel.

```bash
docker exec kamaji-worker-01 bash -c "
  curl -sL https://github.com/containernetworking/plugins/releases/download/v1.5.1/cni-plugins-linux-arm64-v1.5.1.tgz | \
    tar -xz -C /opt/cni/bin
"
```

> For amd64: replace `arm64` with `amd64` in the URL.

### 6.3 Generate bootstrap credentials

```bash
export KUBECONFIG=~/.kube/config

# CA hash
CA_HASH=$(kubectl get secret tenant-demo-ca -n tenant-demo \
  -o jsonpath='{.data.ca\.crt}' | base64 -d | \
  openssl x509 -pubkey -noout | \
  openssl pkey -pubin -outform DER | \
  openssl dgst -sha256 | awk '{print $2}')

# CA data for bootstrap kubeconfig
CA_DATA=$(kubectl get secret tenant-demo-ca -n tenant-demo \
  -o jsonpath='{.data.ca\.crt}')

# Bootstrap token
TOKEN_ID=$(openssl rand -hex 3)
TOKEN_SECRET=$(openssl rand -hex 8)

export KUBECONFIG=~/.kube/tenant-demo-local.kubeconfig
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: bootstrap-token-${TOKEN_ID}
  namespace: kube-system
type: bootstrap.kubernetes.io/token
stringData:
  token-id: "${TOKEN_ID}"
  token-secret: "${TOKEN_SECRET}"
  usage-bootstrap-authentication: "true"
  usage-bootstrap-signing: "true"
  auth-extra-groups: "system:bootstrappers:kubeadm:default-node-token"
EOF

echo "Token: ${TOKEN_ID}.${TOKEN_SECRET}"
```

### 6.4 Configure kubelet

```bash
# Write bootstrap-kubelet.conf
cat > /tmp/bootstrap-kubelet.conf << EOF
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: ${CA_DATA}
    server: https://172.18.255.200:6443
  name: default-cluster
contexts:
- context:
    cluster: default-cluster
    user: tls-bootstrap-token-user
  name: bootstrap-context
current-context: bootstrap-context
kind: Config
preferences: {}
users:
- name: tls-bootstrap-token-user
  user:
    token: ${TOKEN_ID}.${TOKEN_SECRET}
EOF

docker cp /tmp/bootstrap-kubelet.conf \
  kamaji-worker-01:/etc/kubernetes/bootstrap-kubelet.conf

# Disable swap check (swap is enabled in kindest/node)
docker exec kamaji-worker-01 bash -c "
  echo 'KUBELET_EXTRA_ARGS=--fail-swap-on=false' > /etc/default/kubelet
  systemctl restart kubelet
  sleep 3
  systemctl status kubelet --no-pager | grep Active
"
```

### 6.5 Fix kube-proxy

The `kindest/node` container doesn't allow setting `nf_conntrack_max` sysctl. Disable it in the kube-proxy configmap, and provide a kubeconfig:

```bash
export KUBECONFIG=~/.kube/tenant-demo-local.kubeconfig

# Fix conntrack settings
kubectl get configmap kube-proxy -n kube-system -o jsonpath='{.data.config\.conf}' | \
  sed 's/maxPerCore: null/maxPerCore: 0/' | \
  sed 's/min: null/min: 0/' > /tmp/kube-proxy-config.conf

kubectl create configmap kube-proxy -n kube-system \
  --from-file=config.conf=/tmp/kube-proxy-config.conf \
  --dry-run=client -o yaml | kubectl apply -f -

# Create kube-proxy kubeconfig
CA_DATA=$(kubectl --kubeconfig ~/.kube/config get secret tenant-demo-ca \
  -n tenant-demo -o jsonpath='{.data.ca\.crt}')
TOKEN=$(kubectl create token kube-proxy -n kube-system)

cat > /tmp/kube-proxy.conf << EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${CA_DATA}
    server: https://172.18.255.200:6443
  name: default
contexts:
- context:
    cluster: default
    user: kube-proxy
  name: default
current-context: default
users:
- name: kube-proxy
  user:
    token: ${TOKEN}
EOF

docker exec kamaji-worker-01 mkdir -p /var/lib/kube-proxy
docker cp /tmp/kube-proxy.conf kamaji-worker-01:/var/lib/kube-proxy/kubeconfig.conf
kubectl delete pod -n kube-system -l k8s-app=kube-proxy
```

### 6.6 Install Flannel CNI and verify

```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# Delete stuck pods to restart with CNI available
kubectl delete pod -n kube-flannel --all
kubectl delete pod -n kube-system -l k8s-app=coredns
kubectl delete pod -n kube-system -l k8s-app=konnectivity-agent

kubectl get nodes
# NAME        STATUS   ROLES    AGE   VERSION
# worker-01   Ready    <none>   2m    v1.30.2

kubectl get pods -A
# All Running
```

### 6.7 Adding additional worker nodes

The `setup-worker-kind.sh` script accepts an optional worker name — run it again with a different name to join a second node:

```bash
./scripts/setup-worker-kind.sh tenant-demo tenant-demo kamaji-worker-02
```

Verify:

```bash
export KUBECONFIG=~/.kube/tenant-demo-local.kubeconfig
kubectl get nodes
# NAME        STATUS   ROLES    AGE   VERSION
# worker-01   Ready    <none>   1h    v1.30.2
# worker-02   Ready    <none>   30s   v1.30.2
```

Each worker gets its own bootstrap token and joins independently. The hostname inside Kubernetes is derived from the container name — `kamaji-worker-02` registers as `worker-02`.

To remove a worker:

```bash
./scripts/teardown.sh worker kamaji-worker-02
# Then drain the node first
export KUBECONFIG=~/.kube/tenant-demo-local.kubeconfig
kubectl drain worker-02 --ignore-daemonsets --delete-emptydir-data
kubectl delete node worker-02
```

---

## 7. Capsule Multi-Tenancy

Capsule adds soft multi-tenancy to the tenant cluster — namespace groups, quotas, RBAC delegation, and policy enforcement per team.

### 7.1 Install cert-manager and Capsule on tenant cluster

```bash
export KUBECONFIG=~/.kube/tenant-demo-local.kubeconfig

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true \
  --wait

helm install capsule projectcapsule/capsule \
  --namespace capsule-system \
  --create-namespace \
  --wait

kubectl get pods -n capsule-system
```

> Capsule Helm may report `failed` due to `--wait` timeout. Check pods directly — if Running, it's fine.

### 7.2 Enable quota enforcement

```bash
# forceTenantPrefix is required for namespace quota enforcement
# Without it, quotas are advisory only
kubectl patch capsuleconfiguration default --type=merge \
  -p '{"spec":{"forceTenantPrefix":true}}'
```

### 7.3 Quota reconciliation

Capsule v0.13.0 has a reconciliation lag between namespace creation and `status.size` update. The validating webhook reads `status.size` for quota checks — if this is stale, quota won't be enforced.

**After install or any quota change, always restart the controller:**

```bash
kubectl rollout restart deployment/capsule-controller-manager -n capsule-system
kubectl rollout status deployment/capsule-controller-manager -n capsule-system
```

**Patching an existing tenant quota:**

```bash
kubectl patch tenant team-alpha --type=merge -p '{"spec":{"namespaceOptions":{"quota":5}}}'

# Force immediate reconciliation
kubectl rollout restart deployment/capsule-controller-manager -n capsule-system

# Or trigger reconcile without restart
kubectl annotate tenant team-alpha reconcile-trigger="$(date +%s)" --overwrite
```

The `setup-capsule.sh` script handles the initial restart automatically.

### 7.4 Create Team Alpha tenant

```bash
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
EOF

kubectl create clusterrolebinding capsule-alice-provisioner \
  --clusterrole=capsule-namespace-provisioner \
  --user=alice

kubectl get tenants
```

### 7.5 Demo — Tenant isolation and quota enforcement

```bash
# Alice creates namespaces (must use group: projectcapsule.dev)
# forceTenantPrefix requires names to start with team-alpha-
kubectl --as=alice --as-group=projectcapsule.dev create namespace team-alpha-frontend
kubectl --as=alice --as-group=projectcapsule.dev create namespace team-alpha-backend
kubectl --as=alice --as-group=projectcapsule.dev create namespace team-alpha-data

# Verify tenant label applied automatically
kubectl get namespaces -l capsule.clastix.io/tenant=team-alpha
# NAME                  STATUS   AGE
# team-alpha-backend    Active   5s
# team-alpha-data       Active   5s
# team-alpha-frontend   Active   5s

# 4th namespace blocked by quota
kubectl --as=alice --as-group=projectcapsule.dev create namespace team-alpha-overflow
# Error: Cannot exceed Namespace quota: please, reach out to the system administrators

# Wrong prefix also blocked
kubectl --as=alice --as-group=projectcapsule.dev create namespace frontend
# Error: The Namespace name must start with 'team-alpha-'
```

### 7.6 Create Team Beta — second tenant with isolation demo

```bash
kubectl apply -f - <<'EOF'
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

kubectl create clusterrolebinding capsule-bob-provisioner \
  --clusterrole=capsule-namespace-provisioner \
  --user=bob

kubectl create clusterrolebinding capsule-bob-deleter \
  --clusterrole=capsule-namespace-deleter \
  --user=bob

# Bob creates his namespaces
kubectl --as=bob --as-group=projectcapsule.dev create namespace team-beta-api
kubectl --as=bob --as-group=projectcapsule.dev create namespace team-beta-workers

kubectl get namespaces -l capsule.clastix.io/tenant=team-beta
```

### 7.7 Isolation verification

```bash
# Bob can list his namespaces
kubectl --as=bob --as-group=projectcapsule.dev get namespaces
# NAME              STATUS   AGE
# team-beta-api     Active   10s
# team-beta-workers Active   8s

# Bob cannot access team-alpha namespaces
kubectl --as=bob --as-group=projectcapsule.dev get pods -n team-alpha-frontend
# Error from server (Forbidden): pods is forbidden

# Alice cannot access team-beta namespaces
kubectl --as=alice --as-group=projectcapsule.dev get pods -n team-beta-api
# Error from server (Forbidden): pods is forbidden

# Both tenants visible to cluster admin
kubectl get tenants
# NAME         STATE    NAMESPACE QUOTA   NAMESPACE COUNT   READY
# team-alpha   Active   3                 3                 True
# team-beta    Active   3                 2                 True
```

### 7.8 Deploy workloads as a tenant user

```bash
# Bob grants his developer (charlie) access to team-beta-api
kubectl --as=bob --as-group=projectcapsule.dev apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: charlie-developer
  namespace: team-beta-api
subjects:
- kind: User
  name: charlie
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: edit
  apiGroup: rbac.authorization.k8s.io
EOF

# Charlie deploys a workload
kubectl --as=charlie apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: team-beta-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
        - name: nginx
          image: docker.io/nginx:alpine
          ports:
            - containerPort: 80
EOF

kubectl --as=charlie get pods -n team-beta-api
# NAME                     READY   STATUS    RESTARTS   AGE
# nginx-xxx                1/1     Running   0          10s
```

### 7.9 Scoped kubeconfig for tenant users

In production, give each tenant user their own kubeconfig scoped to their namespaces:

```bash
# Create a ServiceAccount for charlie
kubectl create serviceaccount charlie -n team-beta-api
kubectl create rolebinding charlie-edit \
  --clusterrole=edit \
  --serviceaccount=team-beta-api:charlie \
  -n team-beta-api

# Generate a 24h token
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

# Test — charlie can only see team-beta-api
KUBECONFIG=~/.kube/charlie-team-beta.kubeconfig kubectl get pods
KUBECONFIG=~/.kube/charlie-team-beta.kubeconfig kubectl get pods -n team-alpha-frontend
# Error: Forbidden
```

---

## 8. Kamaji Console

The Kamaji Console provides a web dashboard for managing TCPs.

### 8.1 Install

```bash
export KUBECONFIG=~/.kube/config

kubectl create secret generic kamaji-console \
  --namespace kamaji-system \
  --from-literal=NEXTAUTH_URL="http://localhost:8080" \
  --from-literal=JWT_SECRET="$(openssl rand -hex 32)" \
  --from-literal=ADMIN_EMAIL="admin@lab.local" \
  --from-literal=ADMIN_PASSWORD="admin123"

helm upgrade --install kamaji-console clastix/kamaji-console \
  --namespace kamaji-system \
  --set replicaCount=1 \
  --set credentialsSecret.generate=false \
  --set credentialsSecret.name=kamaji-console \
  --wait

kubectl get pods -n kamaji-system | grep console
```

### 8.2 Access

```bash
kubectl port-forward -n kamaji-system svc/kamaji-console 8080:80 &
open http://localhost:8080/ui
```

Login: `admin@lab.local` / `admin123`

> **Gotchas:**
> - URL path is `/ui` not `/` — 404 on root is expected
> - Secret key must be `JWT_SECRET` not `NEXTAUTH_SECRET`
> - Password must be alphanumeric — dots cause silent auth failure
> - Create secret manually — `credentialsSecret.generate=true` is broken in chart v0.1.3

---

## 9. Shell Helpers

Source `scripts/shell-helpers.zsh` in your `~/.zshrc`:

```bash
echo 'source "/path/to/kamaji-lab/scripts/shell-helpers.zsh"' >> ~/.zshrc
source ~/.zshrc
```

| Command | Description |
|---|---|
| `use-mgmt` | Switch to management cluster |
| `use-tenant tenant-demo` | Switch to tenant cluster (starts port-forward) |
| `kamaji-status` | TCP list + pod health overview |
| `kamaji-ui` | Open Kamaji Console in browser |
| `reset-tenant tenant-demo` | Clear kubeconfig cache |

---

## 10. Known Issues

| Issue | Cause | Fix |
|---|---|---|
| TCP version > management cluster version rejected | Kamaji webhook validates K8s version | Use `v1.30.2` with kind v1.34 management cluster |
| Kamaji fails with `TLSRoute CRD not found` | Latest Kamaji watches Gateway API resources | Install experimental Gateway API CRDs before Kamaji |
| MetalLB IP not reachable from Mac | kind Docker network not routed to Mac host | Use `kubectl port-forward` for all tenant access |
| `kubeadm join` hangs on cluster-info | Kamaji TCPs don't create JWS-signed cluster-info ConfigMap | Don't use `kubeadm join` — configure kubelet directly |
| kubelet crashes: `bootstrap-kubelet.conf not found` | kubeadm writes `kubelet.conf` but kubelet expects bootstrap config | Write `bootstrap-kubelet.conf` manually with token |
| kubelet crashes: swap enabled | `kindest/node` has swap enabled | Set `KUBELET_EXTRA_ARGS=--fail-swap-on=false` in `/etc/default/kubelet` |
| kube-proxy crashes: `nf_conntrack_max permission denied` | Container doesn't have sysctl privileges | Set `conntrack.maxPerCore: 0` and `min: 0` in kube-proxy ConfigMap |
| kube-proxy crashes: `kubeconfig.conf not found` | kube-proxy expects `/var/lib/kube-proxy/kubeconfig.conf` | Create kubeconfig manually and copy into container |
| Flannel crashes: `bridge plugin not found` | `kindest/node` missing CNI plugins | Install CNI plugins v1.5.1 from containernetworking/plugins |
| Capsule Helm shows `failed` status | `--wait` timeout — Capsule takes longer than Helm's default | Check pods directly — if Running, installation succeeded |
| Capsule quota not enforced | `forceTenantPrefix` not enabled | Patch CapsuleConfiguration: `forceTenantPrefix: true` |
| Capsule webhook not intercepting | Wrong group used | Use `--as-group=projectcapsule.dev` not `capsule.clastix.io` |
| Capsule secret key error | Secret uses `NEXTAUTH_SECRET` instead of `JWT_SECRET` | Create secret with `JWT_SECRET` key |
| Capsule quota not enforced after install | `status.size` reconciliation lag — webhook reads stale count | Restart controller after install: `kubectl rollout restart deployment/capsule-controller-manager -n capsule-system` |
| Capsule quota not enforced after patch | Same reconciliation lag after changing quota value | Restart controller or trigger reconcile: `kubectl annotate tenant <name> reconcile-trigger="$(date +%s)" --overwrite` |
