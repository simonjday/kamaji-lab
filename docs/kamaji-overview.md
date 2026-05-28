# Kamaji — Hosted Control Plane Manager for Kubernetes

> A technical deep-dive from a kind/macOS admin perspective.  
> Covers architecture, local setup, tenant cluster demo, and web UI tooling.

---

## Table of Contents

1. [What Is Kamaji?](#1-what-is-kamaji)
2. [Architecture](#2-architecture)
3. [Core CRDs](#3-core-crds)
4. [Datastore Options](#4-datastore-options)
5. [Konnectivity — Mixed-Network Support](#5-konnectivity--mixed-network-support)
6. [Cluster API Integration](#6-cluster-api-integration)
7. [Lab Setup on macOS — Choosing Your Base](#7-lab-setup-on-macos--choosing-your-base)
   - [7A. kind](#7a-kind-docker-desktop)
   - [7B. Rancher Desktop](#7b-rancher-desktop-k3s-managed-lima-vm)
   - [7C. Lima + K3s](#7c-lima--k3s-full-control)
   - [7D. Common Kamaji Install](#7d-common-kamaji-install-all-base-options)
   - [7E. Teardown](#7e-teardown-scripts)
   - [7F. Repo Layout](#7f-recommended-repo-layout-for-github)
8. [macOS / kind MetalLB Network Workarounds](#8-macos--kind-metallb-network-workarounds)
9. [Demo — Provision a Tenant Cluster](#9-demo--provision-a-tenant-cluster)
10. [Joining Worker Nodes](#10-joining-worker-nodes)
11. [Web UI & Management Tooling](#11-web-ui--management-tooling)
12. [GitOps Patterns with Kamaji](#12-gitops-patterns-with-kamaji)
13. [Capsule — Soft Multi-Tenancy on Tenant Clusters](#13-capsule--soft-multi-tenancy-on-tenant-clusters)
14. [Kamaji + Capsule — Layered Multi-Tenancy Architecture](#14-kamaji--capsule--layered-multi-tenancy-architecture)
15. [K3s — Lightweight Management Cluster Distribution](#16-k3s--lightweight-management-cluster-distribution)
16. [Cilium — eBPF Networking for the Platform Stack](#17-cilium--ebpf-networking-for-the-platform-stack)
17. [Operational Reference](#18-operational-reference)
18. [Known Issues & API Changes](#19-known-issues--api-changes)

**Appendices**
- [Appendix A — Alternative Base Options (kind & Rancher Desktop)](#appendix-a--alternative-base-options-kind--rancher-desktop)


---

## 1. What Is Kamaji?

Kamaji (by [CLASTIX](https://clastix.io)) is an open-source Kubernetes Operator that turns any conformant cluster into a **Management Cluster** capable of hosting multiple Kubernetes control planes as standard workloads (Pods/Deployments).

The pattern is called **Hosted Control Plane (HCP)** — the same model used by GKE, EKS, AKS, and OpenShift HyperShift, but open-source and infrastructure-agnostic.

### Why it matters

| Traditional multi-cluster | Kamaji HCP |
|---|---|
| Dedicated VMs per control plane | Control planes are pods in the management cluster |
| N×3 control plane nodes minimum | Single management cluster, unlimited tenants |
| etcd on bare metal VMs | Shared or dedicated multi-tenant etcd/PostgreSQL/MySQL |
| Manual cert rotation | Automated via kubeadm + cert-manager |
| No HA for free | Kubernetes Deployment semantics — rolling updates, self-healing |

### What Kamaji is NOT

- Not a VM hypervisor (worker nodes are still real VMs or bare metal)
- Not a vcluster-style fake cluster (control plane is real, CNCF-conformant Kubernetes)
- Not a cloud service — runs entirely on your infrastructure

---

## 2. Architecture

```
┌──────────────────────────────────────────────────────────┐
│                    Management Cluster                     │
│  (your kind-devops-lab or production cluster)            │
│                                                          │
│  ┌─────────────┐   ┌───────────────────────────────┐    │
│  │   Kamaji    │   │        kamaji-system ns        │    │
│  │  Operator   │──▶│  kamaji-controller-manager     │    │
│  └─────────────┘   └───────────────────────────────┘    │
│                                                          │
│  ┌─────────────────────────────────────────────────┐     │
│  │            kamaji-etcd namespace                │     │
│  │  ┌──────────────────────────────────────────┐   │     │
│  │  │  Multi-tenant etcd StatefulSet (3 pods)  │   │     │
│  │  └──────────────────────────────────────────┘   │     │
│  └─────────────────────────────────────────────────┘     │
│                                                          │
│  ┌─────────────────────────────────────────────────┐     │
│  │          tenant-01 namespace                    │     │
│  │  ┌────────────────┐  ┌──────────────────────┐   │     │
│  │  │ kube-apiserver │  │ kube-controller-mgr  │   │     │
│  │  │    (pod)       │  │       (pod)          │   │     │
│  │  └────────────────┘  └──────────────────────┘   │     │
│  │  ┌────────────────┐  ┌──────────────────────┐   │     │
│  │  │ kube-scheduler │  │   konnectivity-server│   │     │
│  │  │    (pod)       │  │       (pod)          │   │     │
│  │  └────────────────┘  └──────────────────────┘   │     │
│  │  ┌──────────────────────────────────────────┐   │     │
│  │  │  LoadBalancer Service → :6443            │   │     │
│  │  └──────────────────────────────────────────┘   │     │
│  └─────────────────────────────────────────────────┘     │
│                                                          │
│  (tenant-02, tenant-03 ... each in own namespace)        │
└──────────────────────────────────────────────────────────┘
            ▲ kubeconfig / join token
            │
  ┌─────────┴────────┐     ┌──────────────────────┐
  │  Worker Node A   │     │   Worker Node B       │
  │  (VM or bare     │     │   (different DC,      │
  │   metal, joins   │     │    cloud, or edge)    │
  │   tenant-01)     │     │                       │
  └──────────────────┘     └──────────────────────┘
```

### Key Design Properties

- **Tenant isolation**: each `TenantControlPlane` runs in its own namespace; tenants have zero visibility into the management cluster
- **CNCF conformant**: uses unmodified upstream `kube-apiserver`, `kube-scheduler`, `kube-controller-manager`; kubeadm manages certs and bootstrap
- **Self-healing**: control plane components are Kubernetes Deployments — they get rescheduled, rolled, and scaled automatically
- **Multi-tenancy on datastore**: multiple TCPs can share a single etcd instance using RBAC key-prefix isolation, reducing operational overhead

---

## 3. Core CRDs

Kamaji ships two CRD pairs.

### 3.1 `TenantControlPlane` (TCP)

The primary resource. One TCP = one tenant Kubernetes cluster (control plane only).

```yaml
apiVersion: kamaji.clastix.io/v1alpha1
kind: TenantControlPlane
metadata:
  name: tenant-01
  namespace: tenant-01
spec:
  dataStore: default         # references a DataStore CR
  controlPlane:
    deployment:
      replicas: 2                # HA control plane
      additionalVolumeMounts: []
    service:
      serviceType: LoadBalancer  # or NodePort/ClusterIP
  kubernetes:
    version: v1.32.0
    kubelet:
      cgroupfs: systemd
  addons:
    coreDNS:
      imageRepository: registry.k8s.io
    kubeProxy: {}
    konnectivity:
      server:
        port: 8132
```

**Status fields of interest:**

```bash
kubectl get tcp -A
# NAME        VERSION   STATUS   CONTROL-PLANE ENDPOINT   KUBECONFIG                    DATASTORE   AGE
# tenant-01   v1.32.0   Ready    172.19.255.200:6443       tenant-01-admin-kubeconfig    default     5m
```

| Status | Meaning |
|---|---|
| `Provisioning` | Certs being issued, pods starting |
| `Ready` | API server healthy, etcd synced |
| `NotReady` | Pod crash or cert issue |
| `Upgrading` | Rolling image update in progress |

### 3.2 `DataStore`

Describes a backing store (etcd, PostgreSQL, MySQL, NATS) that one or more TCPs use.

```yaml
apiVersion: kamaji.clastix.io/v1alpha1
kind: DataStore
metadata:
  name: default
spec:
  driver: etcd
  endpoints:
    - etcd-0.etcd.kamaji-etcd.svc.cluster.local:2379
    - etcd-1.etcd.kamaji-etcd.svc.cluster.local:2379
    - etcd-2.etcd.kamaji-etcd.svc.cluster.local:2379
  tlsConfig:
    certificateAuthority:
      certificate:
        secretReference:
          keyPath: ca.crt
          name: kamaji-etcd-certs
          namespace: kamaji-etcd
      privateKey:
        secretReference:
          keyPath: ca.key
          name: kamaji-etcd-certs
          namespace: kamaji-etcd
    clientCertificate:
      certificate:
        secretReference:
          keyPath: tls.crt
          name: kamaji-etcd-root-client-certs
          namespace: kamaji-etcd
      privateKey:
        secretReference:
          keyPath: tls.key
          name: kamaji-etcd-root-client-certs
          namespace: kamaji-etcd
```

---

## 4. Datastore Options

| Driver | Maturity | Multi-tenancy | Notes |
|---|---|---|---|
| `etcd` (kamaji-etcd) | GA | Yes — RBAC key prefix | Default; 3-node StatefulSet |
| `PostgreSQL` | GA | Yes — separate DB per TCP | Use CloudNativePG in production |
| `MySQL` | GA | Yes — separate DB per TCP | Percona XtraDB or RDS |
| `NATS` | Experimental | **No** — one TCP per NATS | Not recommended for multi-tenant |

### Choosing a datastore strategy

```
Single management cluster, lab/dev
  └─▶ One shared kamaji-etcd (default install)

Production, many tenants
  └─▶ PostgreSQL via CloudNativePG — better ops, backup, PITR

High isolation requirement
  └─▶ Dedicated kamaji-etcd per tenant (--set datastore.enabled=true per install)

Edge / resource-constrained
  └─▶ Single shared etcd is fine; kamaji-etcd is already multi-tenant by design
```

---

## 5. Konnectivity — Mixed-Network Support

Kamaji bundles Konnectivity to handle the case where worker nodes are in a network that cannot directly reach the management cluster (NAT, different DC, VPN gap).

```
  Management Cluster            Worker Node Network
  ┌───────────────────┐         ┌─────────────────────┐
  │ konnectivity-     │◀──TLS──▶│ konnectivity-agent  │
  │ server (pod)      │         │ (DaemonSet on nodes) │
  └───────────────────┘         └─────────────────────┘
        ▲
  kube-apiserver proxies
  kubectl exec / logs / port-forward
  through konnectivity tunnel
```

This is important for edge clusters, hybrid cloud, and any setup where your kind management cluster is on your laptop but worker nodes are VMs on a remote hypervisor.

---

## 6. Cluster API Integration

Kamaji ships a **CAPI Control Plane Provider** (`cluster-api-control-plane-provider-kamaji`), meaning it plugs natively into any CAPI-managed infrastructure.

```
CAPI Core
  ├── Bootstrap Provider  (kubeadm)
  ├── Infrastructure Provider (vSphere / Proxmox / OpenStack / AWS / Azure / MAAS)
  └── Control Plane Provider → Kamaji  ← replaces KubeadmControlPlane
```

With CAPI + Kamaji you get fully declarative cluster lifecycle (create, upgrade, scale, delete) including the worker nodes, driven entirely from `Cluster`, `MachineDeployment`, and `TenantControlPlane` CRs. GitOps-friendly — commit a `Cluster` manifest to Gitea, ArgoCD syncs it, CAPI provisions workers, Kamaji spins the CP.

## 7. Lab Setup on macOS — Lima + K3s

> **This is the tested, recommended path** — all steps in this guide were validated on macOS M3 with Lima 2.1.1 and K3s v1.35.5.
>
> For kind and Rancher Desktop alternatives see **Appendix A** at the end of this document.

K3s is Linux-only. Lima runs a lightweight Linux VM on macOS using Apple Virtualization.framework (`vmType: vz`), giving you a real Linux kernel — full eBPF, real cgroups, real systemd. This is the right base for a Kamaji lab on macOS.

### 7A. kind (Docker Desktop)

#### Prerequisites

```bash
brew install kind helm kubectl
# Docker Desktop must be running
```

#### Create the management cluster

```bash
# scripts/setup-kind.sh
#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-kamaji-mgmt}"

echo "==> Creating kind cluster: ${CLUSTER_NAME}"
cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 16443   # management API passthrough
        hostPort: 16443
        protocol: TCP
      - containerPort: 30001   # tenant-01 TCP (NodePort option)
        hostPort: 7443
        protocol: TCP
      - containerPort: 30002   # tenant-02 TCP
        hostPort: 7444
        protocol: TCP
      - containerPort: 30080   # Kamaji Console
        hostPort: 8080
        protocol: TCP
EOF

kubectl config use-context "kind-${CLUSTER_NAME}"
echo "==> kind cluster ready: $(kubectl get nodes --no-headers | awk '{print $1}')"
```

```bash
chmod +x scripts/setup-kind.sh
./scripts/setup-kind.sh
```

#### Install MetalLB

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.3/config/manifests/metallb-native.yaml
kubectl rollout status daemonset/speaker -n metallb-system --timeout=120s

GW_IP=$(docker network inspect -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' kind)
NET_IP=$(echo "${GW_IP}" | sed -E 's|^([0-9]+\.[0-9]+)\..*$|\1|g')

cat <<EOF | sed -E "s|172.19|${NET_IP}|g" | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
    - 172.19.255.200-172.19.255.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-l2
  namespace: metallb-system
EOF
```

> MetalLB IPs are only reachable inside the Docker VM. See §8 for the four workaround options (port-forward, docker exec, static route, or NodePort mappings).

#### Install cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io && helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set installCRDs=true --wait
```

Then continue to **§7D**.

---

### 7B. Rancher Desktop (K3s, managed Lima VM)

Rancher Desktop bundles K3s inside a Lima VM and exposes it as your default kubeconfig context. It is the lowest-friction path to real K3s on macOS.

#### Prerequisites

```bash
brew install --cask rancher
# Also install the CLI tools
brew install helm kubectl
```

Launch Rancher Desktop from Applications. On first run:

1. **Container runtime**: select `containerd`
2. **Kubernetes version**: pick `v1.32.x` (or latest stable)
3. **Enable Kubernetes**: on
4. Wait for the status bar to show "Kubernetes: Running"

Or drive it entirely from the CLI with `rdctl`:

```bash
# scripts/setup-rancher.sh
#!/usr/bin/env bash
set -euo pipefail

K8S_VERSION="${K8S_VERSION:-v1.32.4+k3s1}"

echo "==> Configuring Rancher Desktop with K3s ${K8S_VERSION}"

# Apply settings via rdctl (Rancher Desktop must already be installed)
rdctl set \
  --kubernetes.enabled=true \
  --kubernetes.version="${K8S_VERSION}" \
  --container-engine.name=containerd \
  --kubernetes.options.flannel=false \
  --kubernetes.options.traefik=false

# This triggers a restart — wait for it
echo "==> Waiting for K3s to become ready (this takes ~60s)..."
sleep 30
until kubectl --context rancher-desktop get nodes --no-headers 2>/dev/null | grep -q Ready; do
  echo "  ... waiting"
  sleep 5
done

kubectl config use-context rancher-desktop
echo "==> Rancher Desktop K3s ready"
kubectl get nodes -o wide
```

```bash
chmod +x scripts/setup-rancher.sh
./scripts/setup-rancher.sh
```

> `--kubernetes.options.flannel=false --kubernetes.options.traefik=false` disables the built-in CNI and ingress so Cilium and your own ingress take over cleanly. If you don't need Cilium for this lab, omit these flags and MetalLB will still work.

#### Discover the Lima VM network

Rancher Desktop's K3s node runs inside a Lima VM. The node IP is routable from your Mac:

```bash
# Get the node IP — this is directly reachable from your Mac terminal
NODE_IP=$(kubectl --context rancher-desktop get nodes \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "K3s node IP: ${NODE_IP}"
# Typically: 192.168.5.15 or 192.168.106.x
```

#### Install MetalLB with routable pool

Because the Lima VM network IS routable from your Mac, MetalLB IPs in the right subnet work directly:

```bash
# scripts/setup-metallb-rancher.sh
#!/usr/bin/env bash
set -euo pipefail

NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
# Build a pool in the same /24 as the node, last 50 addresses
NET_PREFIX=$(echo "${NODE_IP}" | cut -d. -f1-3)
POOL_START="${NET_PREFIX}.200"
POOL_END="${NET_PREFIX}.250"

echo "==> Node IP: ${NODE_IP}"
echo "==> MetalLB pool: ${POOL_START}-${POOL_END}"

kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.3/config/manifests/metallb-native.yaml
kubectl rollout status daemonset/speaker -n metallb-system --timeout=120s

cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lima-pool
  namespace: metallb-system
spec:
  addresses:
    - ${POOL_START}-${POOL_END}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: lima-l2
  namespace: metallb-system
EOF

echo "==> MetalLB ready. IPs in ${POOL_START}-${POOL_END} are directly routable from your Mac."
```

```bash
chmod +x scripts/setup-metallb-rancher.sh
./scripts/setup-metallb-rancher.sh
```

#### Install cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io && helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set installCRDs=true --wait
```

Then continue to **§7D**.

---

### 7C. Lima + K3s (full control)

Lima is the VM layer that both Rancher Desktop and Docker Desktop use under the hood. Using it directly gives you full control over the VM spec, network, and K3s flags — and produces the most reproducible, scriptable setup.

> **Tested on:** macOS 15, Apple M3, Lima 2.1.1, K3s v1.35.5+k3s1

#### Prerequisites

```bash
brew install lima helm kubectl
```

#### Known gotchas before you start

| Issue | Cause | Fix in script |
|---|---|---|
| `FATA: failed to find QEMU binary` | Lima defaults to qemu; macOS needs vz | Script auto-detects and sets `vmType: vz` |
| `did not receive "running" status` | K3s install in provision block exceeds Lima boot timeout | Script separates VM boot from K3s install |
| `cni plugin not initialized` — node never Ready | K3s started with `--flannel-backend=none` but no CNI installed | Script uses Flannel by default; Cilium is opt-in |
| First boot takes 5–10 min | Ubuntu cloud-init runs unattended-upgrades on first boot | Script disables it via a fast provision script |
| K3s installs latest stable not pinned version | `INSTALL_K3S_VERSION` env var not propagated into `limactl shell bash -c` heredoc | Known limitation — script installs latest stable K3s regardless of `K3S_VERSION` |

#### CNI decision for the management cluster

**Use Flannel (default)** — the management cluster just runs Kamaji operator pods. Flannel works, needs zero configuration, and the node is Ready in ~30 seconds after K3s starts.

**Use Cilium** — only needed on the management cluster if you want eBPF networking/observability there. Set `CILIUM_CNI=true` before running the script, then run `setup-cilium.sh` immediately after before the node-ready wait times out.

For most labs: **use Flannel on the management cluster. Install Cilium on tenant clusters instead.**

#### Run the script

```bash
chmod +x scripts/setup-lima-k3s.sh
./scripts/setup-lima-k3s.sh
```

Expected output sequence:

```
==> Lima version: limactl version 2.1.1
==> Arch: arm64 → Lima: aarch64, image: arm64, vmType: vz

==> Step 1/3: Starting Lima VM (Ubuntu only, no K3s yet)
    CPUs:    4  |  Memory: 8 GiB  |  Disk: 40 GiB  |  vmType: vz
...
INFO[0042] READY. Run `limactl shell kamaji-k3s` to open the shell.

==> Step 2/3: Installing K3s inside VM
    CNI: Flannel (built-in, node Ready in ~30s)
  --> Updating apt cache
  --> Installing K3s
[INFO]  Installing k3s to /usr/local/bin/k3s
[INFO]  systemd: Starting k3s
  --> K3s install complete

==> Step 3/3: Waiting for K3s node to become Ready
  ... waiting (0s)
  ... waiting (5s)
==> K3s node is Ready

NAME              STATUS   ROLES           AGE   VERSION
lima-kamaji-k3s   Ready    control-plane   19s   v1.35.5+k3s1
```

> **First boot timing:** Step 1 (VM boot) takes ~3 min on first run due to cloud-init, even with unattended-upgrades disabled. Subsequent `limactl start` resumes in ~15 seconds.

```bash
export KUBECONFIG=~/.kube/k3s-kamaji.kubeconfig
kubectl get nodes
```

#### Install MetalLB (Lima — IPs are directly routable)

Unlike kind, Lima's VM network is routable from your Mac host. MetalLB LoadBalancer IPs work directly — no port-forward needed.

```bash
./scripts/setup-metallb-lima.sh
```

Expected:
```
==> Node IP: 192.168.5.15
==> MetalLB pool: 192.168.5.200-192.168.5.250
==> MetalLB ready. IPs in 192.168.5.200-192.168.5.250 are directly routable from your Mac.
```

#### Install Cilium (optional — management cluster only if needed)

The management cluster uses Flannel by default. Only run this if you specifically want Cilium on the management cluster:

```bash
# First, the VM must have been started with CILIUM_CNI=true
# (deletes and recreates the VM with --flannel-backend=none)
CILIUM_CNI=true ./scripts/setup-lima-k3s.sh

# Then immediately install Cilium before the node-ready timeout
./scripts/setup-cilium.sh
```

Cilium on **tenant clusters** is covered in §17 and does not require recreating the management cluster.

#### Lima convenience aliases

Add to `~/.zshrc`:

```zsh
alias k3s-start='limactl start kamaji-k3s'
alias k3s-stop='limactl stop kamaji-k3s'
alias k3s-shell='limactl shell kamaji-k3s'
alias k3s-logs='limactl shell kamaji-k3s sudo journalctl -u k3s -f'
export KUBECONFIG_K3S="${HOME}/.kube/k3s-kamaji.kubeconfig"
alias use-k3s='export KUBECONFIG=${KUBECONFIG_K3S} && kubectl config use-context kamaji-k3s'
```

---

### 7D. Common Kamaji Install (all base options)

Once your base cluster is running — kind, Rancher Desktop, or Lima — the Kamaji install is identical. The script below detects which context is active.

```bash
# scripts/install-kamaji.sh
#!/usr/bin/env bash
set -euo pipefail

CONTEXT=$(kubectl config current-context)
echo "==> Installing Kamaji on context: ${CONTEXT}"

# ── Helm repos ─────────────────────────────────────────────────────────────────
echo "==> Adding Helm repos"
helm repo add clastix https://clastix.github.io/charts
helm repo add jetstack https://charts.jetstack.io
helm repo update

# ── cert-manager (skip if already installed) ────────────────────────────────
if ! kubectl get ns cert-manager &>/dev/null; then
  echo "==> Installing cert-manager"
  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --set installCRDs=true \
    --wait
else
  echo "==> cert-manager already present, skipping"
fi

# ── Kamaji ─────────────────────────────────────────────────────────────────────
echo "==> Installing Kamaji"
EXTRA_FLAGS=""
# Drop resource requests for kind (lab only)
if echo "${CONTEXT}" | grep -q kind; then
  EXTRA_FLAGS="--set resources=null"
fi

helm upgrade --install kamaji clastix/kamaji \
  --namespace kamaji-system \
  --create-namespace \
  ${EXTRA_FLAGS} \
  --version 0.0.0+latest \
  --wait

# ── Verify ─────────────────────────────────────────────────────────────────────
echo ""
echo "==> Verifying installation"
kubectl get pods -n kamaji-system
kubectl get pods -n kamaji-etcd
kubectl get datastore
kubectl get crds | grep kamaji

echo ""
echo "==> Kamaji installed successfully on ${CONTEXT}"
echo "    Next: create a TenantControlPlane — see Section 9"
```

```bash
chmod +x scripts/install-kamaji.sh
./scripts/install-kamaji.sh
```

#### Install order for Lima path

```bash
export KUBECONFIG=~/.kube/k3s-kamaji.kubeconfig

# 1. MetalLB — must be in place before any TCP is created
./scripts/setup-metallb-lima.sh

# 2. Kamaji (includes cert-manager)
./scripts/install-kamaji.sh

# Cilium is optional on the management cluster — see §7C
```

#### Verified working output (`kubectl get pods -A`)

```
NAMESPACE        NAME                                       READY   STATUS
cert-manager     cert-manager-xxx                           1/1     Running
cert-manager     cert-manager-cainjector-xxx                1/1     Running
cert-manager     cert-manager-webhook-xxx                   1/1     Running
kamaji-system    kamaji-xxx                                 1/1     Running
kamaji-system    kamaji-etcd-0                              1/1     Running
kamaji-system    kamaji-etcd-1                              1/1     Running
kamaji-system    kamaji-etcd-2                              1/1     Running
kube-system      coredns-xxx                                1/1     Running
kube-system      local-path-provisioner-xxx                 1/1     Running
kube-system      metrics-server-xxx                         1/1     Running
metallb-system   controller-xxx                             1/1     Running
metallb-system   speaker-xxx                                1/1     Running
```

All 12 pods running = management cluster is healthy and ready for tenant control planes.

---

### 7E. Teardown Scripts

```bash
# scripts/teardown.sh
#!/usr/bin/env bash
set -euo pipefail

BASE="${1:-kind}"   # kind | rancher | lima

case "${BASE}" in
  kind)
    CLUSTER="${2:-kamaji-mgmt}"
    echo "==> Deleting kind cluster: ${CLUSTER}"
    kind delete cluster --name "${CLUSTER}"
    ;;
  rancher)
    echo "==> Resetting Rancher Desktop Kubernetes"
    rdctl set --kubernetes.enabled=false
    sleep 5
    rdctl set --kubernetes.enabled=true
    echo "==> Done — Rancher Desktop cluster reset"
    ;;
  lima)
    VM="${2:-kamaji-k3s}"
    echo "==> Stopping and deleting Lima VM: ${VM}"
    limactl stop "${VM}"
    limactl delete "${VM}"
    rm -f "${HOME}/.kube/k3s-kamaji.kubeconfig"
    echo "==> Lima VM deleted"
    ;;
  *)
    echo "Usage: $0 <kind|rancher|lima> [cluster/vm name]"
    exit 1
    ;;
esac

echo "==> Teardown complete"
```

```bash
chmod +x scripts/teardown.sh

# Examples:
./scripts/teardown.sh kind kamaji-mgmt
./scripts/teardown.sh lima kamaji-k3s
./scripts/teardown.sh rancher
```

---

### 7F. Recommended repo layout for GitHub

```
kamaji-lab/
├── README.md                      # links to this doc
├── docs/
│   └── kamaji-overview.md         # this file
├── scripts/
│   ├── setup-kind.sh
│   ├── setup-rancher.sh
│   ├── setup-lima-k3s.sh
│   ├── setup-cilium-lima.sh
│   ├── setup-metallb-rancher.sh
│   ├── setup-metallb-lima.sh
│   ├── install-kamaji.sh          # shared across all bases
│   └── teardown.sh
└── manifests/
    ├── tenants/
    │   ├── tenant-demo.yaml       # TenantControlPlane CR
    │   └── tenant-legacy.yaml
    ├── capsule/
    │   └── tenant-team-alpha.yaml
    └── argocd/
        └── kamaji-appset.yaml
```



---

## 8. macOS MetalLB Network Workarounds

> **Lima with usernet (default):** Lima's default network mode is `usernet` (NAT). The `192.168.5.x` subnet is internal to the VM — MetalLB IPs are **not** directly reachable from your Mac host. The same port-forward workarounds from kind apply. See §8A for the `socket_vmnet` fix that makes Lima IPs directly routable.

> **Rancher Desktop:** also uses a NAT network by default. Same situation as Lima usernet.

> **kind:** same — Docker bridge network is not host-routable.

**All three base options require one of the workarounds below by default.** The exception is Lima with `socket_vmnet` enabled (§8A), which gives true direct routing.

Four workaround options, from least to most persistent:

### Option A — `kubectl port-forward` (easiest, no config)

Port-forward directly against the LoadBalancer Service that backs the TCP. No routing changes needed — traffic goes through the management cluster's kube-apiserver.

```bash
# Get the service name (same as TCP name)
kubectl get svc -n tenant-demo

# Forward local port 7443 → TCP service port 6443
kubectl port-forward svc/tenant-demo -n tenant-demo 7443:6443 &

# Patch the kubeconfig to point at localhost
sed -i '' 's|172.19.255.200:6443|127.0.0.1:7443|g' /tmp/tenant-demo.kubeconfig

export KUBECONFIG=/tmp/tenant-demo.kubeconfig
kubectl get nodes
```

> Works for interactive use. The `port-forward` process will die if idle — wrap it: `while true; do kubectl port-forward svc/tenant-demo -n tenant-demo 7443:6443; sleep 1; done &`

### Option B — `docker exec` into the kind container (zero config, immediate)

The kind control-plane container lives inside the Docker VM where the `kind` bridge **is** routable. Run `kubectl` from inside the container where MetalLB IPs work natively.

```bash
# Find the management cluster container
CONTAINER=$(docker ps --filter "name=kamaji-mgmt-control-plane" --format '{{.Names}}')

# Copy the tenant kubeconfig into the container
docker cp /tmp/tenant-demo.kubeconfig ${CONTAINER}:/tmp/tenant-demo.kubeconfig

# Run kubectl from inside the container — MetalLB IPs are routable here
docker exec -it ${CONTAINER} kubectl \
  --kubeconfig /tmp/tenant-demo.kubeconfig \
  get nodes

# Or drop into an interactive shell
docker exec -it ${CONTAINER} bash
export KUBECONFIG=/tmp/tenant-demo.kubeconfig
kubectl get pods -A
```

> Best for quick verification or scripted checks. Not ergonomic for long interactive sessions.

### Option C — Static route on macOS host (persistent until reboot)

Add a host route so the MetalLB pool is directly reachable from your Mac terminal.

```bash
# Step 1: Get the kind bridge gateway (the gateway IP inside Docker VM)
GW_IP=$(docker network inspect -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' kind)
echo "Kind bridge gateway: ${GW_IP}"
# Typically: 172.19.0.1

# Step 2: Discover the Docker Desktop VM's IP as seen from your Mac
# Docker Desktop exposes a magic hostname for this:
DOCKER_VM_IP=$(docker run --rm alpine getent hosts host.docker.internal | awk '{print $1}')
echo "Docker VM host IP: ${DOCKER_VM_IP}"
# Typically: 192.168.65.254 (varies by Docker Desktop version)

# Step 3: Add a static route for the MetalLB pool
NET_IP=$(echo "${GW_IP}" | sed -E 's|^([0-9]+\.[0-9]+)\..*$|\1|g')
sudo route -n add -net "${NET_IP}.255.0/24" "${DOCKER_VM_IP}"
# e.g. sudo route -n add -net 172.19.255.0/24 192.168.65.254

# Step 4: Verify connectivity
ping -c 1 172.19.255.200

# Step 5: Use kubeconfig normally
export KUBECONFIG=/tmp/tenant-demo.kubeconfig
kubectl get nodes
```

**Make permanent across reboots with a LaunchDaemon:**

```bash
# Create the route script
cat > /usr/local/bin/kind-routes.sh << 'EOF'
#!/bin/bash
DOCKER_VM_IP=$(docker run --rm alpine getent hosts host.docker.internal 2>/dev/null | awk '{print $1}')
[ -z "${DOCKER_VM_IP}" ] && exit 1
sudo route -n add -net 172.19.255.0/24 "${DOCKER_VM_IP}" 2>/dev/null || true
EOF
chmod +x /usr/local/bin/kind-routes.sh
```

```xml
<!-- /Library/LaunchDaemons/io.local.kind-routes.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key>        <string>io.local.kind-routes</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/kind-routes.sh</string>
  </array>
  <key>RunAtLoad</key>    <true/>
  <key>StandardErrorPath</key>  <string>/var/log/kind-routes.log</string>
  <key>StandardOutPath</key>    <string>/var/log/kind-routes.log</string>
</dict></plist>
```

```bash
sudo launchctl load /Library/LaunchDaemons/io.local.kind-routes.plist
```

> ⚠️ The Docker Desktop VM IP can change across upgrades. The `getent hosts host.docker.internal` call in the script handles this dynamically at each boot.

### Option D — kind `extraPortMappings` + NodePort (cleanest for fixed lab TCPs)

Pre-map specific TCP service ports through to your Mac at kind cluster creation time. This punches through Docker NAT entirely — no routing required.

```yaml
# kind-kamaji.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: kamaji-mgmt
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 16443   # management cluster kube-apiserver
        hostPort: 16443
        protocol: TCP
      - containerPort: 30001   # tenant-demo TCP
        hostPort: 7443
        protocol: TCP
      - containerPort: 30002   # tenant-legacy TCP
        hostPort: 7444
        protocol: TCP
      - containerPort: 30080   # Kamaji Console
        hostPort: 8080
        protocol: TCP
```

```bash
kind create cluster --config kind-kamaji.yaml
```

Create the TCP with `serviceType: NodePort` and a fixed `nodePort`:

```yaml
spec:
  controlPlane:
    service:
      serviceType: NodePort
      nodePort: 30001     # → hostPort 7443 on your Mac
```

```bash
# Patch the generated kubeconfig to use localhost
sed -i '' 's|.*server:.*|    server: https://127.0.0.1:7443|' /tmp/tenant-demo.kubeconfig
export KUBECONFIG=/tmp/tenant-demo.kubeconfig
kubectl get nodes
```

> Best approach for a long-lived lab with a fixed set of 2–4 tenant clusters. Pre-plan your NodePort → hostPort mapping (e.g. 30001→7443, 30002→7444, 30003→7445) at cluster creation — you cannot add `extraPortMappings` to an existing kind cluster.

### Option summary

| Scenario | Recommended |
|---|---|
| Quick one-off check | Option B (`docker exec`) |
| Interactive dev session (ad-hoc) | Option A (`port-forward`) |
| Running scripts / CI against TCPs | Option C (static route) |
| Permanent lab, fixed set of TCPs | Option D (`extraPortMappings` + NodePort) |

---

### 8A. Lima socket_vmnet — True Direct Routing (recommended for Lima)

`socket_vmnet` gives Lima a bridged network interface so the VM gets an IP on your Mac's LAN and MetalLB IPs are routable directly from your host — no port-forward needed.

#### Install

```bash
# Install socket_vmnet (requires sudo for the launchd daemon)
brew install socket_vmnet
brew tap homebrew/services
sudo brew services start socket_vmnet

# Grant Lima permission to use it
limactl sudoers | sudo tee /etc/sudoers.d/lima
```

#### Recreate the Lima VM with bridged networking

```bash
# Tear down the existing VM
./scripts/teardown.sh lima kamaji-k3s

# Recreate with socket_vmnet — pass the network type via env var
LIMA_NETWORK=bridged ./scripts/setup-lima-k3s.sh
```

The script detects `LIMA_NETWORK=bridged` and adds the network config to the Lima YAML:

```yaml
networks:
  - lima: bridged
    interface: lima0
```

After setup, `limactl list` will show a real IP (e.g. `192.168.64.x`) instead of blank. That IP is routable from your Mac and MetalLB IPs in the same subnet work directly.

#### Verify

```bash
limactl list kamaji-k3s
# NAME         STATUS    SSH               VMTYPE   ARCH      IP
# kamaji-k3s   Running   127.0.0.1:...     vz       aarch64   192.168.64.5

# MetalLB pool will be in the same /24
curl -k https://192.168.5.200:6443/version   # works directly
```

> If you're not ready to set up `socket_vmnet`, use `kubectl port-forward` (Option A above) — it works reliably for interactive lab use.


---

## 9. Demo — Provision a Tenant Cluster

> **Management cluster context required** for all commands in §9.1–9.3:
> `export KUBECONFIG=~/.kube/k3s-kamaji.kubeconfig`

### 9.1 Create namespace and TCP

```bash
kubectl create namespace tenant-demo

cat <<'EOF' | kubectl apply -f -
apiVersion: kamaji.clastix.io/v1alpha1
kind: TenantControlPlane
metadata:
  name: tenant-demo
  namespace: tenant-demo
spec:
  dataStore: default          # field is "dataStore" not "dataStoreName" in current Kamaji
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
```

### 9.2 Watch provisioning

```bash
kubectl get tcp -n tenant-demo -w
kubectl get pods -n tenant-demo -w
```

Expected — all 4 containers in one pod (~90 seconds):

```
NAME                           READY   STATUS    AGE
tenant-demo-5dcf88674b-xxx     4/4     Running   107s
```

> In current Kamaji versions all four control plane components (apiserver, controller-manager, scheduler, konnectivity-server) run as containers in a single Deployment pod, not as separate pods.

### 9.3 Extract the kubeconfig

Use the helper script (handles port-forward for Lima usernet automatically):

```bash
./scripts/get-tenant-kubeconfig.sh tenant-demo tenant-demo
```

Or manually:

```bash
# Get the admin kubeconfig secret
kubectl get secret tenant-demo-admin-kubeconfig -n tenant-demo \
  -o jsonpath='{.data.admin\.conf}' | base64 -d > ~/.kube/tenant-demo.kubeconfig

# Get the TCP endpoint
TCP_ENDPOINT=$(kubectl get tcp tenant-demo -n tenant-demo \
  -o jsonpath='{.status.controlPlaneEndpoint}')
echo "TCP endpoint: ${TCP_ENDPOINT}"
```

**Lima usernet (default):** the endpoint IP (`192.168.5.x`) is not routable from your Mac. Start a port-forward and patch the kubeconfig:

```bash
# Terminal 1 — keep this running
export KUBECONFIG=~/.kube/k3s-kamaji.kubeconfig
kubectl port-forward svc/tenant-demo -n tenant-demo 7443:6443

# Terminal 2
sed "s|https://${TCP_ENDPOINT}|https://127.0.0.1:7443|g" \
  ~/.kube/tenant-demo.kubeconfig > ~/.kube/tenant-demo-local.kubeconfig
export KUBECONFIG=~/.kube/tenant-demo-local.kubeconfig
kubectl config use-context kubernetes-admin@tenant-demo
```

**Lima with socket_vmnet (§8A):** endpoint is directly reachable, no patch needed:

```bash
export KUBECONFIG=~/.kube/tenant-demo.kubeconfig
kubectl config use-context kubernetes-admin@tenant-demo
```

### 9.4 Explore the tenant cluster

```bash
# Confirm you're talking to the tenant, not the management cluster
kubectl cluster-info
# Kubernetes control plane is running at https://127.0.0.1:7443 (or direct IP)

kubectl version
# Server Version: v1.32.0   ← tenant cluster version

# No workers yet — control plane only
kubectl get nodes
# No resources found

# Namespaces already exist — control plane is fully initialised
kubectl get namespaces
# NAME              STATUS   AGE
# default           Active   Xm
# kube-node-lease   Active   Xm
# kube-public       Active   Xm
# kube-system       Active   Xm

# CoreDNS is Pending — correct, needs a worker node to schedule onto
kubectl get pods -n kube-system
# NAME                       READY   STATUS    RESTARTS
# coredns-xxx                0/1     Pending   0
# coredns-xxx                0/1     Pending   0
```

CoreDNS pending is expected and correct. The control plane is fully operational — you can create namespaces, apply RBAC, deploy manifests. Nothing will schedule until a worker joins.

### 9.5 Provision a second tenant cluster (different version)

Switch back to management cluster context first:

```bash
export KUBECONFIG=~/.kube/k3s-kamaji.kubeconfig

kubectl create namespace tenant-legacy

cat <<'EOF' | kubectl apply -f -
apiVersion: kamaji.clastix.io/v1alpha1
kind: TenantControlPlane
metadata:
  name: tenant-legacy
  namespace: tenant-legacy
spec:
  dataStore: default
  controlPlane:
    deployment:
      replicas: 1
    service:
      serviceType: LoadBalancer
  kubernetes:
    version: v1.30.0
  addons:
    coreDNS: {}
    kubeProxy: {}
    konnectivity:
      server:
        port: 8132
EOF
```

```bash
kubectl get tcp -A
# NAMESPACE       NAME             VERSION   STATUS   CONTROL-PLANE ENDPOINT    AGE
# tenant-demo     tenant-demo      v1.32.0   Ready    192.168.5.200:6443        Xm
# tenant-legacy   tenant-legacy    v1.30.0   Ready    192.168.5.201:6443        Xm
```

Two isolated Kubernetes clusters — different versions, different etcd key prefixes, different kubeconfigs — running as pods in one management cluster.

### 9.6 Upgrade a tenant cluster

```bash
export KUBECONFIG=~/.kube/k3s-kamaji.kubeconfig

kubectl patch tcp tenant-demo -n tenant-demo \
  --type=merge \
  -p '{"spec":{"kubernetes":{"version":"v1.33.0"}}}'

kubectl get tcp -n tenant-demo -w
# STATUS changes: Ready → Upgrading → Ready
```

Kamaji replaces the pod with a new one running the upgraded images, rotating certificates automatically. No etcd migration required.

### 9.7 Delete a tenant cluster

```bash
kubectl delete tcp tenant-legacy -n tenant-legacy
kubectl delete namespace tenant-legacy
# Kamaji removes all pods, services, secrets, and the etcd key prefix for this tenant
```

### 9.8 What's next — continuing the lab

You now have a working Kamaji management cluster and at least one tenant control plane. The natural progression:

| Step | What | Section |
|---|---|---|
| **Join a worker node** | Give the TCP real nodes so workloads can schedule; CoreDNS starts running | §10 |
| **Install Capsule on tenant** | Add namespace-level multi-tenancy inside the tenant cluster | §13 |
| **Install Cilium on tenant** | Replace kube-proxy with eBPF networking on the tenant cluster | §17 |
| **Spin up Kamaji Console** | Web UI to manage all TCPs without kubectl | §11 |
| **GitOps-manage TCPs** | Commit TCP manifests to Gitea, sync via ArgoCD ApplicationSet | §12 |
| **HA control plane** | Set `replicas: 2` on the TCP Deployment for production resilience | §3.1 |
| **PostgreSQL datastore** | Replace shared etcd with CloudNativePG for better ops and PITR | §4 |

**Joining a Multipass worker node (tested, working on macOS M3 + Lima usernet):**

```bash
export KUBECONFIG=~/.kube/k3s-kamaji.kubeconfig
./scripts/setup-worker-node.sh tenant-demo tenant-demo
```

See §10 for the full walkthrough and explanation of why Multipass is used instead of Lima.

---

## 10. Joining Worker Nodes

> **Tested setup:** macOS M3, Lima usernet management cluster, Multipass worker VM, Kamaji v0.x, K8s v1.32

### Why kubeadm join doesn't work with Kamaji out of the box

`kubeadm join` uses token-based discovery which requires a JWS-signed `cluster-info` ConfigMap in the tenant cluster's `kube-public` namespace. Kamaji TCPs don't auto-create this — it's normally created by `kubeadm init` which Kamaji bypasses. The join hangs indefinitely at `Waiting for the cluster-info ConfigMap`.

The working approach: configure kubelet directly with a kubeconfig and static files, bypassing kubeadm discovery entirely.

### Why Multipass not Lima for workers

Lima usernet (SLIRP) isolates each VM in its own NAT stack. `worker-01` and `kamaji-k3s` cannot reach each other directly — they have the same `192.168.5.x` addresses but no L2 connectivity between them.

Multipass uses bridged networking and assigns a real routable IP (e.g. `192.168.252.2`) that the Mac can reach and vice versa. The Mac acts as the bridge: a port-forward bound on `0.0.0.0` lets the Multipass VM reach the TCP service via the Mac gateway IP.

```
Multipass worker-01 (192.168.252.2)
  ↓ connects to 192.168.252.1:16443 (Mac gateway)
Mac host (port-forward 0.0.0.0:16443 → localhost:16443)
  ↓ port-forward
TCP service (192.168.5.200:6443 inside Lima VM)
```

### Network architecture

```
Lima kamaji-k3s VM
  └── MetalLB 192.168.5.200:6443  ← TCP LoadBalancer (only reachable inside Lima)

Mac host
  └── kubectl port-forward :7443   → 192.168.5.200:6443  (for your kubectl)
  └── kubectl port-forward :16443  → 192.168.5.200:6443  (for worker kubelet, 0.0.0.0)

Multipass worker-01 (192.168.252.2)
  └── kubelet → 192.168.252.1:16443 (Mac gateway) → TCP API server
```

### TCP certSANs

The TCP API server TLS certificate is issued for `192.168.5.200` and `127.0.0.1` by default. The worker connects via `192.168.252.1` (Mac gateway) which causes an x509 SAN mismatch. Fix by patching the TCP:

```bash
export KUBECONFIG=~/.kube/k3s-kamaji.kubeconfig
kubectl patch tcp tenant-demo -n tenant-demo --type=merge -p '{
  "spec": {
    "networkProfile": {
      "certSANs": ["192.168.252.1"]
    }
  }
}'

# Wait for TCP to reissue certs and return to Ready (~30s)
kubectl get tcp -n tenant-demo -w
```

### Automated setup

```bash
export KUBECONFIG=~/.kube/k3s-kamaji.kubeconfig
./scripts/setup-worker-node.sh tenant-demo tenant-demo
```

The script handles everything: Multipass VM creation, containerd + kubelet install, certSANs patch, port-forwards, kubelet config, Flannel CNI, and node Ready verification.

### Manual step-by-step

**Prerequisites:**

```bash
brew install multipass
multipass launch --name worker-01 --cpus 2 --memory 4G --disk 20G jammy
WORKER_IP=$(multipass info worker-01 | grep IPv4 | awk '{print $2}')
GATEWAY_IP=$(echo "${WORKER_IP}" | awk -F. '{print $1"."$2"."$3".1"}')
echo "Worker: ${WORKER_IP}, Gateway: ${GATEWAY_IP}"
```

**Start port-forwards (keep running):**

```bash
export KUBECONFIG=~/.kube/k3s-kamaji.kubeconfig
# For kubectl
kubectl port-forward svc/tenant-demo -n tenant-demo 7443:6443 --address 127.0.0.1 &
# For kubelet (bound on all interfaces)
kubectl port-forward svc/tenant-demo -n tenant-demo 16443:6443 --address 0.0.0.0 &
```

**Patch certSANs:**

```bash
kubectl patch tcp tenant-demo -n tenant-demo --type=merge -p '{
  "spec": {"networkProfile": {"certSANs": ["192.168.252.1"]}}
}'
kubectl get tcp -n tenant-demo -w   # wait for Ready
```

**Install containerd + kubelet on worker:**

```bash
multipass exec worker-01 -- bash -c "
  sudo apt-get update -qq
  sudo apt-get install -y containerd
  sudo mkdir -p /etc/containerd
  containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
  sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  sudo systemctl restart containerd && sudo systemctl enable containerd

  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key |     sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg 2>/dev/null
  echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' |     sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
  sudo apt-get update -qq && sudo apt-get install -y kubelet
  sudo swapoff -a
  sudo modprobe overlay br_netfilter
  printf 'net.bridge.bridge-nf-call-iptables=1
net.ipv4.ip_forward=1
' | sudo tee /etc/sysctl.d/k8s.conf > /dev/null
  sudo sysctl --system -q
"
```

**Configure kubelet:**

```bash
# Copy CA cert
kubectl get secret tenant-demo-ca -n tenant-demo   --kubeconfig ~/.kube/k3s-kamaji.kubeconfig   -o jsonpath='{.data.ca\.crt}' | base64 -d |   multipass exec worker-01 -- bash -c "sudo mkdir -p /etc/kubernetes/pki && sudo tee /etc/kubernetes/pki/ca.crt > /dev/null"

# Write kubelet.conf
CLIENT_CERT=$(grep client-certificate-data ~/.kube/tenant-demo-local.kubeconfig | awk '{print $2}')
CLIENT_KEY=$(grep client-key-data ~/.kube/tenant-demo-local.kubeconfig | awk '{print $2}')

multipass exec worker-01 -- bash -c "
cat <<EOF | sudo tee /etc/kubernetes/kubelet.conf > /dev/null
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority: /etc/kubernetes/pki/ca.crt
    server: https://192.168.252.1:16443
  name: tenant-demo
contexts:
- context:
    cluster: tenant-demo
    user: kubernetes-admin
  name: kubernetes-admin@tenant-demo
current-context: kubernetes-admin@tenant-demo
users:
- name: kubernetes-admin
  user:
    client-certificate-data: ${CLIENT_CERT}
    client-key-data: ${CLIENT_KEY}
EOF

sudo mkdir -p /var/lib/kubelet
cat <<KUBECFG | sudo tee /var/lib/kubelet/config.yaml > /dev/null
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook
clusterDNS: ["10.96.0.10"]
clusterDomain: cluster.local
KUBECFG

echo 'KUBELET_KUBEADM_ARGS="--container-runtime-endpoint=unix:///var/run/containerd/containerd.sock --hostname-override=worker-01"' |   sudo tee /var/lib/kubelet/kubeadm-flags.env > /dev/null
sudo systemctl daemon-reload && sudo systemctl restart kubelet
"
```

**Install Flannel CNI and verify:**

```bash
export KUBECONFIG=~/.kube/tenant-demo-local.kubeconfig
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

kubectl get nodes -w
# NAME        STATUS   ROLES    AGE   VERSION
# worker-01   Ready    <none>   72s   v1.32.13

kubectl get pods -A
# CoreDNS now Running — cluster is schedulable
```

### Verified output

```
NAME        STATUS   ROLES    AGE   VERSION     INTERNAL-IP     OS-IMAGE
worker-01   Ready    <none>   72s   v1.32.13    192.168.252.2   Ubuntu 22.04.5 LTS
```

### Required port-forwards — all four must stay running

| Port | Bound on | Purpose |
|---|---|---|
| `7443` | `127.0.0.1` | Your `kubectl` commands |
| `16443` | `0.0.0.0` | kubelet → TCP API server |
| `6443` | `192.168.252.1` | Pod ClusterIP routing (kube-proxy maps `10.96.0.1` here) |
| `8132` | `192.168.252.1` | konnectivity agent tunnel |

If any of these die the effects are:
- `7443` down → your kubectl stops working
- `16443` down → node goes `NotReady` within ~40s
- `6443` down → Flannel crashes, CoreDNS can't start, all pods stuck `ContainerCreating`
- `8132` down → konnectivity loses tunnel, `kubectl logs/exec` stops working

`use-tenant` starts all four automatically:

```bash
use-tenant tenant-demo
```

To restart manually:

```bash
export KUBECONFIG=~/.kube/k3s-kamaji.kubeconfig
GATEWAY=192.168.252.1
while true; do kubectl port-forward svc/tenant-demo -n tenant-demo 7443:6443 --address 127.0.0.1 2>/dev/null; sleep 2; done &
while true; do kubectl port-forward svc/tenant-demo -n tenant-demo 16443:6443 --address 0.0.0.0 2>/dev/null; sleep 2; done &
while true; do kubectl port-forward svc/tenant-demo -n tenant-demo 6443:6443 --address ${GATEWAY} 2>/dev/null; sleep 2; done &
while true; do kubectl port-forward svc/tenant-demo -n tenant-demo 8132:8132 --address ${GATEWAY} 2>/dev/null; sleep 2; done &
```

### Ubuntu 22.04 worker — additional fixes required

These are handled automatically by `setup-worker-node.sh` but documented here for reference:

**1. iptables-legacy** — Ubuntu 22.04 defaults to nftables which is incompatible with kube-proxy:
```bash
sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
```

**2. br_netfilter** — required by Flannel, not loaded by default:
```bash
sudo modprobe br_netfilter
echo br_netfilter | sudo tee /etc/modules-load.d/br_netfilter.conf
```

**3. DNS loop** — systemd-resolved stub on `127.0.0.53` causes CoreDNS to forward to itself:
```bash
echo 'DNSStubListener=no' | sudo tee -a /etc/systemd/resolved.conf
sudo systemctl restart systemd-resolved
sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
```

**4. crictl config** — prevents endpoint detection hangs:
```bash
sudo tee /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF
```

**5. RBAC for kubelet proxy** — allows `kubectl logs` and `kubectl exec`:
```bash
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kube-apiserver-kubelet-client
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kubelet-api-admin
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: User
  name: kube-apiserver-kubelet-client
EOF
```

---

## 11. Web UI & Management Tooling

### 11.1 Kamaji Console (official)

The Kamaji Console (by Clastix) is a Next.js web dashboard deployed into the management cluster. It provides a real-time view of all TenantControlPlanes, datastores, and cluster health without kubectl.

> **Tested on:** Kamaji Console v0.2.1 (chart 0.1.3), K3s management cluster

**Gotchas before install:**

| Issue | Fix |
|---|---|
| Secret key `NEXTAUTH_SECRET` rejected | App requires `JWT_SECRET` — exact key name matters |
| `credentialsSecret.generate=true` fails | Helm template issue — create the secret manually first |
| Login page shows "string did not match" | `JWT_SECRET` env var missing from the pod |
| Login fails with "Invalid email or password" | Password containing `.` or special chars causes silent auth failure — use alphanumeric passwords |
| 404 at `localhost:8080` | App serves on `/ui` subpath — use `http://localhost:8080/ui` |

**Install:**

```bash
export KUBECONFIG=~/.kube/k3s-kamaji.kubeconfig

# Step 1: Create secret manually (Helm generate flag is broken in v0.1.3)
# IMPORTANT: Use JWT_SECRET not NEXTAUTH_SECRET
# IMPORTANT: Password must be alphanumeric — dots/special chars cause auth failure
kubectl create secret generic kamaji-console \
  --namespace kamaji-system \
  --from-literal=NEXTAUTH_URL="http://localhost:8080" \
  --from-literal=JWT_SECRET="$(openssl rand -hex 32)" \
  --from-literal=ADMIN_EMAIL="admin@lab.local" \
  --from-literal=ADMIN_PASSWORD="admin123"

# Step 2: Install chart pointing at existing secret
helm upgrade --install kamaji-console clastix/kamaji-console \
  --namespace kamaji-system \
  --set replicaCount=1 \
  --set credentialsSecret.generate=false \
  --set credentialsSecret.name=kamaji-console \
  --wait

kubectl get pods -n kamaji-system | grep console
```

**Access:**

```bash
kubectl port-forward -n kamaji-system svc/kamaji-console 8080:80 &
open http://localhost:8080/ui
```

Login: `admin@lab.local` / `admin123`

**Dashboard:**

The main TCP list view shows all tenant control planes at a glance:

```
Name         Namespace    Status   Pods  Endpoint              Version  Datastore    Age
tenant-demo  tenant-demo  Ready    1/1   192.168.5.200:6443   v1.32.0  default etcd 4h
```

Features available in the free tier:

| Feature | Notes |
|---|---|
| TCP list | All TCPs, status, pods, endpoint, version, datastore, age |
| CREATE button | Form-based TCP provisioning without writing YAML |
| DOWNLOAD button | Downloads the admin kubeconfig for any TCP |
| DELETE button | Removes a TCP with confirmation |
| Datastore view | Lists registered DataStore resources |

Features requiring PRO licence: Application Delivery (Sveltos), Infrastructure Drivers, Authentication, Auditing, Monitoring, Backup and Restore.

**Add to shell-helpers.zsh:**

```zsh
alias kamaji-ui='kubectl port-forward -n kamaji-system svc/kamaji-console 8080:80 --kubeconfig ${KUBECONFIG_MGMT} & sleep 1 && open http://localhost:8080/ui'
```

**Expose via Ingress (optional):**

```yaml
# values-console.yaml
ingress:
  enabled: true
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
  hosts:
    - host: kamaji.lab.local
      paths:
        - path: /ui
          pathType: Prefix
```

### 11.2 Freelens + Kamaji Extension

[Freelens](https://github.com/freelensapp/freelens) is the maintained open-source fork of Lens. The Kamaji extension adds a dedicated **Tenant Control Planes** section alongside normal cluster views.

**Install Freelens (macOS):**

```bash
brew install --cask freelens
# or download from https://github.com/freelensapp/freelens/releases
```

**Install the Kamaji extension:**

1. Open Freelens → **Extensions** (puzzle icon in sidebar)
2. Search for `freelens-kamaji-extension` or install from URL:
   ```
   https://github.com/freelensapp/freelens-kamaji-extension
   ```
3. Add your management cluster kubeconfig to Freelens

**Extension features:**

- Lists all `TenantControlPlane` resources across namespaces
- Shows status, endpoint, version, datastore at a glance
- One-click switch to tenant cluster context (opens new cluster tab)
- Certificate expiry visibility

### 11.3 kubectl-kamaji Plugin

CLI companion for day-to-day TCP management.

```bash
# Install
go install github.com/clastix/kamaji-kubectl-plugin@latest

# Or via krew (if published)
kubectl krew install kamaji
```

**Commands:**

```bash
# List all TCPs
kubectl kamaji get tcp --all-namespaces

# Get kubeconfig for a TCP
kubectl kamaji kubeconfig --namespace tenant-demo tenant-demo > /tmp/tenant-demo.kubeconfig

# Generate a worker node join token
kubectl kamaji join-token --namespace tenant-demo tenant-demo

# Rotate certificates for a TCP
kubectl kamaji rotate-certificate --namespace tenant-demo tenant-demo
```

### 11.4 Sveltos (Addon Management)

[Sveltos](https://projectsveltos.github.io/sveltos/) is the recommended companion for managing addons across Kamaji tenant clusters. It integrates with the Kamaji Console for a unified view.

```bash
# Register a tenant cluster with Sveltos
# Sveltos reads the TCP admin kubeconfig and reconciles addon policies

kubectl apply -f - <<'EOF'
apiVersion: lib.projectsveltos.io/v1alpha1
kind: SveltosCluster
metadata:
  name: tenant-demo
  namespace: mgmt
spec:
  kubeconfigName: tenant-demo-admin-kubeconfig
  kubeconfigKeyName: admin.conf
EOF
```

With Sveltos you can template `ClusterProfile` resources to deploy CNI, ingress controllers, or any Helm chart to all tenants matching a label selector — a clean GitOps model for fleet-wide addon management.

---

## 12. GitOps Patterns with Kamaji

Kamaji is GitOps-native — all resources are declarative CRs. Typical ArgoCD structure:

```
gitea/
  apps/
    kamaji/
      datastores/
        default-etcd.yaml         # DataStore CR
        postgres-prod.yaml        # DataStore CR (PostgreSQL)
      tenants/
        tenant-demo/
          namespace.yaml
          tcp.yaml                 # TenantControlPlane CR
          network-policies.yaml
        tenant-legacy/
          namespace.yaml
          tcp.yaml
```

**ArgoCD ApplicationSet:**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: kamaji-tenants
  namespace: argocd
spec:
  generators:
    - git:
        repoURL: http://gitea.gitea.svc.cluster.local/platform/kamaji
        revision: main
        directories:
          - path: tenants/*
  template:
    metadata:
      name: '{{path.basename}}'
    spec:
      project: platform
      source:
        repoURL: http://gitea.gitea.svc.cluster.local/platform/kamaji
        targetRevision: main
        path: '{{path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{path.basename}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```
---

## 13. Capsule — Soft Multi-Tenancy on Tenant Clusters

Capsule (by [Project Capsule](https://projectcapsule.dev), originally CLASTIX, now CNCF Sandbox) is a Kubernetes Operator that implements **soft multi-tenancy inside a single cluster**. Where Kamaji gives you hard isolation via separate control planes, Capsule gives you policy-enforced namespace grouping within a single control plane.

They are complementary — not alternatives. The typical pattern from the Medium article's architecture stack is:

```
Kamaji  →  provides isolated control planes per team/customer (hard multi-tenancy)
Capsule →  provides namespace-group isolation within each tenant cluster (soft multi-tenancy)
```

### 13.1 The Problem Capsule Solves

Kubernetes namespaces are flat — there is no native hierarchy. Without Capsule:

- Cluster admins become a bottleneck for every namespace creation
- No way to group namespaces under a single quota boundary
- No way to propagate NetworkPolicies or LimitRanges automatically to new namespaces
- `kubectl get namespaces` exposes all namespaces to all users

Capsule introduces the **Tenant** abstraction: a cluster-scoped resource that groups namespaces and inherits policies to all of them automatically.

### 13.2 Architecture

```
Cluster Admin
  │
  └── creates Tenant CR ──────────────────────────────┐
                                                       │
  ┌────────────────────────────────────────────────────▼──┐
  │                    Tenant: team-alpha                  │
  │                                                        │
  │  Owners: alice, bob                                    │
  │  Namespace quota: max 5                                │
  │  Resource budget: 8 CPU / 16Gi RAM total               │
  │  Allowed registries: [docker.io, ghcr.io]              │
  │  Node selector: env=prod                               │
  │                                                        │
  │  ┌──────────────┐  ┌──────────────┐  ┌─────────────┐  │
  │  │  ns: alpha-  │  │  ns: alpha-  │  │ ns: alpha-  │  │
  │  │  frontend    │  │  backend     │  │ data        │  │
  │  │              │  │              │  │             │  │
  │  │ (policies    │  │ (policies    │  │ (policies   │  │
  │  │  inherited)  │  │  inherited)  │  │  inherited) │  │
  │  └──────────────┘  └──────────────┘  └─────────────┘  │
  └────────────────────────────────────────────────────────┘

Admission Webhook intercepts every namespace/resource creation
and validates/mutates against the Tenant spec.
```

### 13.3 Role Model

| Role | Can do | Cannot do |
|---|---|---|
| **Cluster Admin** | Create/delete Tenants, set budgets and policies | — |
| **Tenant Owner** | Create namespaces within their Tenant, manage team RBAC | Access other tenants, cluster-level resources |
| **Tenant User** | Deploy workloads in tenant namespaces | Create namespaces, modify quotas |

### 13.4 Install

> **Important:** Capsule requires cert-manager for its webhook certificates. Install cert-manager on the **tenant cluster** first — the one on the management cluster is not accessible from within the tenant.

```bash
# Switch to tenant cluster
export KUBECONFIG=~/.kube/tenant-demo-local.kubeconfig

# Step 1: cert-manager on the tenant cluster
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true \
  --wait

kubectl get pods -n cert-manager

# Step 2: Capsule
helm repo add projectcapsule https://projectcapsule.github.io/charts
helm repo update
helm install capsule projectcapsule/capsule \
  --namespace capsule-system \
  --create-namespace \
  --wait

kubectl get pods -n capsule-system
# capsule-controller-manager-xxx   1/1   Running
```

Or use the script (handles both steps):

```bash
./scripts/setup-capsule.sh ~/.kube/tenant-demo-local.kubeconfig
```

### 13.5 Configure quota enforcement

By default in Capsule v0.13.0, namespace quotas are **not enforced** by the admission webhook. Enable `forceTenantPrefix` which both enforces quotas and requires namespace names to be prefixed with the tenant name:

```bash
kubectl patch capsuleconfiguration default --type=merge -p '{
  "spec": {
    "forceTenantPrefix": true
  }
}'
```

With this enabled:
- Namespace `team-alpha-frontend` ✅ allowed (correct prefix)
- Namespace `frontend` ❌ blocked (missing prefix)
- 4th namespace when quota is 3 ❌ blocked (`Cannot exceed Namespace quota`)

### 13.6 Capsule Proxy (optional but recommended)

Without the proxy, `kubectl get namespaces` returns all namespaces or nothing, depending on RBAC. Capsule Proxy sits in front of the API server and filters responses to only show the calling user's tenant resources.

```bash
helm install capsule-proxy projectcapsule/capsule-proxy \
  --namespace capsule-system \
  --set "options.oidcUsernameClaim=preferred_username" \
  --wait
```

Users connect to the Capsule Proxy endpoint instead of kube-apiserver directly. From their perspective, `kubectl get namespaces` returns only their tenant's namespaces.

### 13.7 Tenant CR — Full Example

> **Capsule v0.13.0 deprecation notes:** `containerRegistries`, `limitRanges`, and `networkPolicies` fields still work but generate deprecation warnings. They will be removed in a future release — the new approach uses `TenantReplication` resources. The example below uses the current working syntax.

```yaml
apiVersion: capsule.clastix.io/v1beta2
kind: Tenant
metadata:
  name: team-alpha
spec:
  owners:
    - name: alice
      kind: User
    - name: alpha-devs
      kind: Group

  namespaceOptions:
    quota: 3

  resourceQuotas:
    scope: Tenant
    items:
      - hard:
          limits.cpu: "8"
          limits.memory: 16Gi
          requests.cpu: "4"
          requests.memory: 8Gi
          pods: "20"

  nodeSelector:
    env: prod

  storageClasses:
    allowed:
      - standard

  ingressOptions:
    allowedClasses:
      allowed:
        - nginx
    allowedHostnames:
      allowedRegex: "^.*\.alpha\.example\.com$"
```

Grant the tenant owner namespace provisioning rights (required):

```bash
kubectl apply -f - <<EOF
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
EOF
```

### 13.8 Tenant Resource Replication

Capsule can automatically propagate resources (Secrets, ConfigMaps, etc.) into every namespace in a tenant. Useful for image pull secrets or shared TLS certs.

```yaml
# TenantResource — inject a pull secret into every alpha namespace
apiVersion: capsule.clastix.io/v1beta2
kind: TenantResource
metadata:
  name: registry-pull-secret
  namespace: team-alpha-frontend   # any namespace belonging to the tenant
spec:
  resyncPeriod: 60s
  resources:
    - namespaceSelector:
        matchLabels:
          capsule.clastix.io/tenant: team-alpha
      rawItems:
        - apiVersion: v1
          kind: Secret
          metadata:
            name: regcred
          type: kubernetes.io/dockerconfigjson
          data:
            .dockerconfigjson: <base64-encoded-creds>
```

### 13.9 Demo — Create a Tenant and use it

> **Critical:** Capsule intercepts requests from users in the group `projectcapsule.dev`. Always pass `--as-group=projectcapsule.dev` when impersonating tenant users. Using `capsule.clastix.io` (the old group name) will not trigger the Capsule webhook.

```bash
# Create the Tenant with forceTenantPrefix enabled
kubectl patch capsuleconfiguration default --type=merge -p '{"spec":{"forceTenantPrefix":true}}'

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
          limits.cpu: "4"
          limits.memory: 8Gi
          pods: "20"
EOF

# Grant alice namespace provisioner rights
kubectl create clusterrolebinding capsule-alice-provisioner \
  --clusterrole=capsule-namespace-provisioner \
  --user=alice

# Check tenant state
kubectl get tenants
# NAME         STATE    NAMESPACE QUOTA   NAMESPACE COUNT   READY
# team-alpha   Active   3                 0                 True

# Create namespaces as alice — must use group projectcapsule.dev
# Name must start with team-alpha- (forceTenantPrefix)
kubectl --as=alice --as-group=projectcapsule.dev create namespace team-alpha-frontend
kubectl --as=alice --as-group=projectcapsule.dev create namespace team-alpha-backend
kubectl --as=alice --as-group=projectcapsule.dev create namespace team-alpha-data

# Verify tenant label applied automatically
kubectl get namespaces -l capsule.clastix.io/tenant=team-alpha
# NAME                   STATUS   AGE
# team-alpha-backend     Active   5s
# team-alpha-data        Active   5s
# team-alpha-frontend    Active   5s

# Quota enforced — 4th namespace blocked
kubectl --as=alice --as-group=projectcapsule.dev create namespace team-alpha-overflow
# Error from server (Forbidden): admission webhook denied the request:
# Cannot exceed Namespace quota: please, reach out to the system administrators

# Wrong prefix also blocked
kubectl --as=alice --as-group=projectcapsule.dev create namespace frontend
# Error: The Namespace name must start with 'team-alpha-'

# View full tenant status
kubectl get tenant team-alpha -o jsonpath='{.status.size}'
# 3
```

### 13.10 Demo — Add a Second Tenant

Add `team-beta` with a different owner (`bob`) running alongside `team-alpha` in the same tenant cluster.

```bash
export KUBECONFIG=~/.kube/tenant-demo-local.kubeconfig

# Create the tenant
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
          limits.cpu: "4"
          limits.memory: 8Gi
          pods: "10"
EOF

# Grant bob provisioner rights
kubectl create clusterrolebinding capsule-bob-provisioner \
  --clusterrole=capsule-namespace-provisioner \
  --user=bob

kubectl create clusterrolebinding capsule-bob-deleter \
  --clusterrole=capsule-namespace-deleter \
  --user=bob

# Verify both tenants exist
kubectl get tenants
# NAME         STATE    NAMESPACE QUOTA   NAMESPACE COUNT   READY
# team-alpha   Active   3                 3                 True
# team-beta    Active   3                 0                 True
```

Bob creates his namespaces:

```bash
kubectl --as=bob --as-group=projectcapsule.dev create namespace team-beta-api
kubectl --as=bob --as-group=projectcapsule.dev create namespace team-beta-workers

kubectl get namespaces -l capsule.clastix.io/tenant=team-beta
# NAME              STATUS   AGE
# team-beta-api     Active   5s
# team-beta-workers Active   3s
```

**Verify isolation** — bob cannot see or access team-alpha namespaces:

```bash
# Bob can list his own namespaces
kubectl --as=bob --as-group=projectcapsule.dev get namespaces
# NAME              STATUS   AGE
# team-beta-api     Active   30s
# team-beta-workers Active   28s

# Bob cannot access team-alpha namespaces
kubectl --as=bob --as-group=projectcapsule.dev get pods -n team-alpha-frontend
# Error from server (Forbidden): pods is forbidden: User "bob" cannot list resource "pods"
# in API group "" in the namespace "team-alpha-frontend"
```

---

### 13.11 Demo — Deploy Workloads as a Tenant User

This shows the full self-service flow: tenant owner creates a namespace, grants their team access, and developers deploy workloads — all without cluster-admin involvement.

#### Step 1 — Tenant owner creates namespace and grants team access

```bash
# Bob creates a namespace for his team
kubectl --as=bob --as-group=projectcapsule.dev create namespace team-beta-api

# Bob grants his developer (charlie) access to the namespace
# Capsule auto-binds tenant owners as namespace admins — they can manage RBAC within their namespaces
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
```

#### Step 2 — Developer deploys a workload

```bash
# Charlie deploys an nginx pod to team-beta-api
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

# Verify the deployment
kubectl --as=charlie get pods -n team-beta-api
# NAME                     READY   STATUS    RESTARTS   AGE
# nginx-xxx                1/1     Running   0          30s
```

#### Step 3 — Expose the workload with a Service

```bash
kubectl --as=charlie apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: nginx
  namespace: team-beta-api
spec:
  selector:
    app: nginx
  ports:
    - port: 80
      targetPort: 80
EOF

kubectl --as=charlie get svc -n team-beta-api
# NAME    TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
# nginx   ClusterIP   10.96.x.x      <none>        80/TCP    5s
```

#### Step 4 — Verify resource quota is tracked

```bash
# Check quota consumption across all team-beta namespaces
kubectl get resourcequota -n team-beta-api
# NAME                        AGE   REQUEST                       LIMIT
# capsule-team-beta-api-xxx   1m    pods: 1/10, cpu: 0/2, ...    ...

# Tenant-level aggregate (across all team-beta namespaces)
kubectl get tenant team-beta -o jsonpath='{.status.size}'
# 2  (two namespaces in use)
```

#### Step 5 — Verify registry policy enforcement

```bash
# Charlie tries to use an unauthorized registry — blocked by Capsule admission
# (requires containerRegistries set on the tenant — add it to the Tenant spec first)
kubectl --as=charlie apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: bad-image
  namespace: team-beta-api
spec:
  containers:
    - name: app
      image: privateregistry.internal.com/myapp:latest
EOF
# Error from server (Forbidden): admission webhook denied the request:
# Registry privateregistry.internal.com is not allowed for the current Tenant
```

---

### 13.12 Switching kubectl Context to Act as a Tenant User

In a real platform, tenant users have their own kubeconfigs scoped to their namespaces. For lab use, `--as` impersonation simulates this. In production the pattern is:

**Option A — Capsule Proxy (recommended)**

Install Capsule Proxy (§13.6) and give each tenant a kubeconfig pointing at the proxy endpoint. The proxy intercepts list calls and filters to the user's tenant namespaces — `kubectl get namespaces` only shows their own.

**Option B — Scoped kubeconfig (no proxy)**

Create a ServiceAccount in the tenant namespace, generate a token, and give the user a kubeconfig using that token:

```bash
# Create a ServiceAccount for charlie in team-beta-api
kubectl create serviceaccount charlie -n team-beta-api

# Bind charlie to the edit role in the namespace
kubectl create rolebinding charlie-edit \
  --clusterrole=edit \
  --serviceaccount=team-beta-api:charlie \
  -n team-beta-api

# Generate a token (valid 24h)
TOKEN=$(kubectl create token charlie -n team-beta-api --duration=24h)

# Get the cluster CA and API server endpoint
CA=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
SERVER=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')

# Write charlie's kubeconfig
cat > ~/.kube/charlie-team-beta.kubeconfig <<EOF
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

# Test — charlie's view is scoped to team-beta-api
KUBECONFIG=~/.kube/charlie-team-beta.kubeconfig kubectl get pods
KUBECONFIG=~/.kube/charlie-team-beta.kubeconfig kubectl get pods -n team-alpha-frontend
# Error: charlie cannot access other tenant namespaces
```

**Option C — Shell helper**

Add to `~/.zshrc` for quick impersonation in the lab:

```zsh
function use-as() {
  local USER=$1
  local NS=${2:-""}
  local EXTRA=""
  [ -n "${NS}" ] && EXTRA="-n ${NS}"
  echo "==> Acting as: ${USER} (group: projectcapsule.dev)"
  echo "    kubectl --as=${USER} --as-group=projectcapsule.dev ${EXTRA} <command>"
  alias k="kubectl --as=${USER} --as-group=projectcapsule.dev"
}

# Usage:
# use-as alice           # act as alice (any namespace)
# use-as bob team-beta-api  # act as bob scoped to namespace
# k get pods -n team-beta-api
```


---

## 14. Kamaji + Capsule — Layered Multi-Tenancy Architecture

This is the architecture described in the referenced Medium post: K3s/kind + Kamaji + Capsule + Kamaji Console as a unified platform engineering stack.

```
Platform Team (Cluster Admins)
  │
  ├── Management Cluster (kind-devops-lab / K3s)
  │     ├── Kamaji Operator
  │     ├── kamaji-etcd
  │     └── Kamaji Console (web UI)
  │
  └── Provisions Tenant Clusters via TenantControlPlane CRs
        │
        ├── Tenant Cluster A  (e.g. "team-alpha production")
        │     ├── Capsule Operator (installed as addon)
        │     ├── Tenant: frontend-team
        │     │     ├── ns: frontend-prod
        │     │     └── ns: frontend-staging
        │     └── Tenant: backend-team
        │           ├── ns: backend-prod
        │           └── ns: backend-workers
        │
        └── Tenant Cluster B  (e.g. "team-beta dev")
              ├── Capsule Operator
              └── Tenant: beta-devs
                    └── ns: beta-dev-*
```

### When to use which layer

| Isolation need | Use |
|---|---|
| Different Kubernetes versions | Kamaji (separate TCPs) |
| Blast radius containment (etcd, API server) | Kamaji |
| Regulatory / compliance boundary | Kamaji |
| Team-level namespace grouping within a cluster | Capsule |
| Self-service namespace creation for developers | Capsule |
| Resource budgeting across namespaces | Capsule |
| Registry allow-listing per team | Capsule |
| Cross-team NetworkPolicy isolation | Capsule |

### Installing Capsule into a Kamaji Tenant Cluster

```bash
# Switch to the tenant cluster kubeconfig
export KUBECONFIG=/tmp/tenant-demo.kubeconfig

# Install Capsule into the tenant cluster
helm repo add projectcapsule https://projectcapsule.github.io/charts
helm install capsule projectcapsule/capsule \
  --namespace capsule-system \
  --create-namespace \
  --wait

# Capsule is now running inside the TCP pods in the management cluster
# (from Kamaji's perspective, it's just workloads in the tenant cluster)
kubectl get pods -n capsule-system
```

### GitOps-managing Capsule Tenants across multiple TCPs

With ArgoCD ApplicationSets, you can define a `Tenant` CR once and replicate it to any TCP that matches a label selector:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: capsule-tenants
  namespace: argocd
spec:
  generators:
    - clusters:
        selector:
          matchLabels:
            capsule-enabled: "true"   # label your TCP-backed clusters in ArgoCD
  template:
    metadata:
      name: 'capsule-tenants-{{name}}'
    spec:
      project: platform
      source:
        repoURL: http://gitea.gitea.svc.cluster.local/platform/capsule-tenants
        targetRevision: main
        path: tenants
      destination:
        server: '{{server}}'
        namespace: capsule-system
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
```

### Capsule + Kyverno

Since you're already running Kyverno, Capsule and Kyverno are complementary rather than overlapping:

| Responsibility | Tool |
|---|---|
| Namespace grouping, quota aggregation, tenant RBAC delegation | **Capsule** |
| Pod-level policy enforcement (resource limits, image signatures, securityContext) | **Kyverno** |
| Cross-namespace resource propagation with templating | **Capsule TenantResource** |
| Cluster-wide mutation (add labels, inject sidecars) | **Kyverno** |
| Allowed registries per tenant | **Capsule** (registry allow-list in Tenant CR) |
| Image signature verification | **Kyverno** |

The usual pattern: Capsule owns the tenant boundary; Kyverno owns workload-level enforcement within that boundary.


### Real-world scenario: 500-engineer company (from the article)

This is the pattern the article describes for a company with 30 product teams running a mix of AWS, bare-metal, and 40 edge retail sites:

```
Infrastructure
  ├── AWS EC2 (elastic workloads)
  ├── Bare-metal colocation (2 sites, batch/cost-sensitive)
  └── Edge K3s nodes (40 retail stores)

Management Cluster (3 control-plane + 10 worker, on AWS)
  ├── Cilium (CNI + Hubble observability)
  ├── Kamaji (hosts 8 tenant control planes)
  │     ├── tenant/engineering      → AWS worker nodes
  │     ├── tenant/data             → bare-metal worker nodes
  │     ├── tenant/ai-ml            → GPU nodes on AWS
  │     ├── tenant/retail-edge      → K3s edge nodes, 40 stores
  │     └── tenant/...             (one per BU/region/trust boundary)
  ├── Kamaji Console (platform team dashboard)
  └── ArgoCD (App of Apps for all tenants)

Inside each Tenant Cluster
  ├── Cilium (CNI — same tooling, consistent policy model)
  ├── Capsule (subdivides the cluster among product teams)
  │     ├── Capsule Tenant: team-checkout
  │     ├── Capsule Tenant: team-search
  │     ├── Capsule Tenant: team-recs
  │     └── ...
  └── ArgoCD (per-tenant GitOps)

Developer Portal (centrally hosted)
  └── Backstage — service catalog, onboarding templates
        └── Template: "new team" → creates Capsule Tenant on appropriate cluster
```

**Cost outcome**: 8 tenant control planes ≈ cost of 8 small Deployments (~few hundred $/month) vs 8× managed cluster fees (~$560+/month on EKS alone). Platform team: 6 engineers instead of 60.

### When this stack makes sense

Use it when:

- You have more than one cluster and the count is growing
- You have multiple internal customers (teams, BUs, products, or paying customers)
- Cost of managed Kubernetes is meaningful at your scale
- You have a small dedicated platform team
- You need a mix of edge, on-prem, and cloud

Skip it when:

- One cluster, three engineers — use a managed service instead
- No platform team to operate it
- Your org would be better served by a managed PaaS (Cloud Run, Fly.io, Render)
- You're early-stage and infrastructure costs are dominated by your application, not control planes

> The stack pays off when you're running enough Kubernetes that the meta-work of running Kubernetes becomes its own discipline.

---

## 16. K3s — Lightweight Management Cluster Distribution

K3s is the distribution the article's production stack uses as the base for the management cluster (in place of kind for anything beyond a local lab). Understanding it matters because Kamaji's prerequisites are just "a conformant Kubernetes cluster" — K3s satisfies that in a ~512MB footprint.

### What K3s is

K3s packages the entire Kubernetes control plane into a single binary under 60MB. It is CNCF-certified Kubernetes — every API, every resource type, the same conformance tests. The trade-offs vs upstream Kubernetes:

| Aspect | Upstream Kubernetes | K3s |
|---|---|---|
| Binary size | Multiple GBs of containers | Single binary, ~60MB |
| Default datastore | etcd (separate cluster) | Embedded SQLite (swappable to etcd, PostgreSQL, MySQL) |
| Default CNI | None — you pick | Flannel (replaceable with Cilium) |
| Default ingress | None | Traefik (disable-able) |
| Memory footprint | ~2GB realistic minimum | ~512MB workable minimum |
| Install | Multi-step, multiple manifests | `curl -sfL https://get.k3s.io \| sh -` |

### K3s architecture

```
K3s Server Node (Control Plane)
  ├── kube-apiserver
  ├── kube-scheduler
  ├── kube-controller-manager
  ├── Datastore (SQLite by default, or embedded etcd / external DB)
  ├── Traefik (ingress, disable-able)
  ├── CoreDNS
  ├── Local-Path Provisioner (storage)
  └── kubelet (co-located)

K3s Agent Node (Worker)
  ├── kubelet
  ├── containerd
  └── kube-proxy (or Cilium in kube-proxy replacement mode)
```

### Quick install (for a K3s management cluster)

```bash
# Server (control plane)
curl -sfL https://get.k3s.io | sh -

# Wait for node ready
sudo k3s kubectl get nodes

# Get kubeconfig
sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config-k3s
# Fix the server IP if needed (defaults to 127.0.0.1)
sed -i 's/127.0.0.1/<SERVER_IP>/g' ~/.kube/config-k3s
export KUBECONFIG=~/.kube/config-k3s
```

```bash
# Worker node — grab token from server first
# cat /var/lib/rancher/k3s/server/node-token

curl -sfL https://get.k3s.io |   K3S_URL=https://<SERVER_IP>:6443   K3S_TOKEN=<node-token> sh -
```

### K3s + Kamaji — production install variant

For a production-grade management cluster, disable Flannel and Traefik so Cilium and your own ingress take over:

```bash
curl -sfL https://get.k3s.io | sh -s -   --flannel-backend=none   --disable-network-policy   --disable=traefik   --cluster-cidr=10.42.0.0/16   --service-cidr=10.43.0.0/16   --write-kubeconfig-mode 644
```

Then install Cilium (see section 17), then proceed with cert-manager → kamaji-etcd → Kamaji as per section 7.

### When to use K3s vs kind for the management cluster

| Scenario | Use |
|---|---|
| Local lab, Mac-only, throw-away | kind |
| Persistent lab VM, Raspberry Pi, home server | K3s |
| Edge sites, retail nodes, factory gateways | K3s |
| Production management cluster on a VM or bare-metal | K3s (or full Kubernetes) |
| CI pipeline ephemeral cluster | K3s |

---

## 17. Cilium — eBPF Networking for the Platform Stack

Cilium is the CNI the article's stack uses on both the management cluster and every tenant cluster. It replaces Flannel/kube-proxy with an eBPF dataplane that is faster, more observable, and enforces L3/L4/L7 policy natively.

### Why eBPF vs iptables matters at scale

Traditional kube-proxy uses iptables rules evaluated linearly. With 10,000 services you have 10,000+ iptables rules traversed per packet. eBPF uses hash-map lookups — O(1) regardless of fleet size. The practical difference shows up at 500+ nodes or 1000+ services.

```
Traditional path (iptables):
  Pod → veth → iptables PREROUTING (walk N rules) → conntrack → DNAT
  → FORWARD chain (walk N rules) → POSTROUTING (SNAT) → destination pod
  Latency: O(N rules). CPU: High. Visibility: None.

Cilium eBPF path:
  Pod → veth → eBPF program (attached at ingress, O(1) map lookup)
  → policy check in-kernel → eBPF load balance → destination pod
  → event published to Hubble (per-flow visibility)
  Latency: O(1). CPU: Low. Visibility: Full.
```

### What Cilium provides in this stack

| Feature | Notes |
|---|---|
| CNI (pod networking) | Every pod gets an IP, full east-west traffic |
| NetworkPolicy (L3/L4) | Standard Kubernetes NetworkPolicy + Cilium-extended CiliumNetworkPolicy |
| L7 policy | HTTP/gRPC/Kafka-aware rules ("only GET /api/v1/health") |
| kube-proxy replacement | Full eBPF-based service load balancing, no iptables |
| WireGuard / IPsec encryption | Transparent node-to-node encryption, zero app changes |
| Hubble observability | Per-flow visibility, service dependency maps, DNS history |
| Service mesh (optional) | mTLS, traffic shifting, retries — without sidecar injection |

### Install on K3s (management cluster)

K3s must be started with `--flannel-backend=none --disable-network-policy` (see section 16) before Cilium is installed.

```bash
# Install Cilium CLI
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --remote-name-all   https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-arm64.tar.gz
tar xzvf cilium-linux-arm64.tar.gz
sudo mv cilium /usr/local/bin

# Install Cilium into the cluster
cilium install   --set kubeProxyReplacement=true   --set k8sServiceHost=<APISERVER_IP>   --set k8sServicePort=6443

# Wait for all pods ready
cilium status --wait
```

### Enable Hubble (observability)

```bash
cilium hubble enable --ui

# Port-forward the Hubble UI
cilium hubble ui &
# Opens http://localhost:12000 — service dependency map, flow logs, DNS
```

### Install on a Kamaji Tenant Cluster

After a TCP is provisioned and worker nodes are joined:

```bash
export KUBECONFIG=/tmp/tenant-demo.kubeconfig

# Tenant cluster's API server endpoint
TCP_IP=$(kubectl --kubeconfig ~/.kube/config   get tcp tenant-demo -n tenant-demo   -o jsonpath='{.status.controlPlaneEndpoint}' | cut -d: -f1)

cilium install   --set kubeProxyReplacement=true   --set k8sServiceHost="${TCP_IP}"   --set k8sServicePort=6443

cilium status --wait
```

### Cilium + Capsule NetworkPolicy integration

Capsule injects standard `NetworkPolicy` resources into tenant namespaces. Cilium enforces them at the eBPF layer. For stronger L7 isolation between Capsule tenants, add `CiliumNetworkPolicy`:

```yaml
# Block all cross-tenant traffic at L7 — per-tenant, managed by Capsule TenantResource
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: deny-cross-tenant
  namespace: team-alpha-frontend
spec:
  endpointSelector: {}
  ingress:
    - fromEndpoints:
        - matchLabels:
            capsule.clastix.io/tenant: team-alpha
  egress:
    - toEndpoints:
        - matchLabels:
            capsule.clastix.io/tenant: team-alpha
    - toFQDNs:
        - matchPattern: "*.cluster.local"
    - toPorts:
        - ports:
            - port: "443"
              protocol: TCP
```

---

## 19. Known Issues & API Changes

A changelog of issues discovered during real lab use on macOS M3 with Lima + K3s.

| Issue | Symptom | Fix |
|---|---|---|
| `spec.dataStoreName` rejected | `strict decoding error: unknown field "spec.dataStoreName"` | Use `spec.dataStore` (renamed in recent Kamaji releases) |
| TCP pods show 4/4 not 4 separate pods | Expected 4 pods, see 1 pod with 4 containers | Current Kamaji runs all CP components in one Deployment pod — normal |
| Lima `--memory 8GiB` flag fails | `strconv.ParseFloat: parsing "8GiB": invalid syntax` | Use a Lima YAML config file; memory as `"8GiB"` string is valid in YAML |
| Lima boot timeout with K3s in provision block | `did not receive "running" status` after 600s | Separate VM boot from K3s install — boot plain Ubuntu, then install K3s via `limactl shell` |
| Node stuck `NotReady` after K3s install | `cni plugin not initialized` in logs | K3s started with `--flannel-backend=none` but no CNI installed; use Flannel (default) on management cluster |
| Lima first boot takes 5–10 min | Stuck on `boot scripts must have finished` | Ubuntu runs unattended-upgrades on first boot; disable via provision script |
| Lima `vmType: qemu` fails on M-series Mac | `qemu-system-aarch64: executable file not found` | Use `vmType: vz` (Apple Virtualization.framework, built into macOS 13+) |
| MetalLB IPs not reachable from Mac | `curl: (28) Failed to connect` to `192.168.5.x` | Lima default is usernet (NAT) — use `kubectl port-forward` or install `socket_vmnet` for bridged networking (§8A) |
| Empty kubeconfig after extraction | `clusters: null, contexts: null` | Secret key is `admin.conf` — use `kubectl get secret ... -o jsonpath='{.data.admin\.conf}'` |
| `error: no context exists with the name: "default"` | Context name in tenant kubeconfig is `kubernetes-admin@<tcp-name>` | Run `kubectl config get-contexts` to find the actual context name |
| K3s version pinning ignored | `INSTALL_K3S_VERSION` env var ignored in `limactl shell bash -c` heredoc | Known limitation — script installs latest stable K3s; pin version by running `INSTALL_K3S_VERSION=vX.Y.Z+k3s1 curl -sfL https://get.k3s.io \| sh` manually inside the VM |
| `kubeadm join` hangs on `cluster-info` | Kamaji TCPs don't auto-create the JWS-signed `cluster-info` ConfigMap kubeadm discovery requires | Don't use `kubeadm join` — configure kubelet directly with a kubeconfig (see §10) |
| Lima worker can't reach MetalLB IP | Lima usernet SLIRP isolates VMs — `worker-01` can't reach `192.168.5.200` | Use Multipass for worker nodes — provides real bridged networking |
| x509 SAN mismatch on kubelet | TCP cert issued for `192.168.5.200`, worker connects via Mac gateway `192.168.252.1` | Patch `spec.networkProfile.certSANs: ["192.168.252.1"]` on the TCP and wait for cert reissue |
| Worker goes NotReady after port-forward dies | kubelet continuously needs `192.168.252.1:16443` — if port-forward stops, node loses API connectivity within ~40s | Use `use-tenant` shell helper which restarts both port-forwards; or run port-forwards in a persistent tmux session |
| containerd missing on worker | `kubeadm join` warns about missing CRI socket | Install containerd before kubelet: `sudo apt-get install -y containerd` then configure SystemdCgroup |
| Port 10250 already in use on management VM | Running kubelet inside kamaji-k3s Lima VM fails — K3s already uses port 10250 | Don't run worker kubelet inside the management VM — use a separate Multipass VM |
| kube-proxy incompatible with nftables | `iptables v1.8.7 (nf_tables): chain KUBE-SERVICES incompatible` — Ubuntu 22.04 uses nftables by default | Run `sudo update-alternatives --set iptables /usr/sbin/iptables-legacy` on the worker |
| br_netfilter not loaded | Flannel crashes: `stat /proc/sys/net/bridge/bridge-nf-call-iptables: no such file or directory` | Run `sudo modprobe br_netfilter` and persist with `/etc/modules-load.d/k8s.conf` |
| CoreDNS DNS loop on Ubuntu 22.04 | `[FATAL] plugin/loop: Loop detected` — systemd-resolved stub listens on `127.0.0.53`, `/etc/resolv.conf` points there, CoreDNS forwards to itself | Disable stub: `DNSStubListener=no` in `/etc/systemd/resolved.conf`, symlink `/etc/resolv.conf` to `/run/systemd/resolve/resolv.conf` |
| Konnectivity agent can't connect | `dial tcp 192.168.252.1:8132: connect: connection refused` | Add port-forward for port 8132: `kubectl port-forward svc/tenant-demo -n tenant-demo 8132:8132 --address 192.168.252.1` |
| `kubectl logs` forbidden | `Forbidden (user=kube-apiserver-kubelet-client, verb=get, resource=nodes, subresource=proxy)` | Apply ClusterRoleBinding: `kube-apiserver-kubelet-client` → `system:kubelet-api-admin` |
| Flannel can't reach API server | `dial tcp 10.96.0.1:443: i/o timeout` — kubernetes ClusterIP not routable from worker | Patch TCP `advertiseAddress` to Mac gateway IP and add port-forward on `0.0.0.0:6443` bound to gateway IP |
| `crictl` hangs | crictl tries multiple CRI endpoints sequentially, each with long timeout | Create `/etc/crictl.yaml` with `runtime-endpoint: unix:///run/containerd/containerd.sock` |
| Kamaji reconciles CoreDNS ConfigMap back | Manual edits to CoreDNS ConfigMap are overwritten by Kamaji | Fix root cause (DNS stub) instead of editing ConfigMap — Kamaji owns it |
| Capsule install fails: `Certificate` CRD not found | Capsule webhook requires cert-manager CRDs — these must be on the **tenant** cluster, not just the management cluster | Install cert-manager on the tenant cluster first: `helm install cert-manager jetstack/cert-manager --set installCRDs=true` |
| Capsule namespace creation forbidden | User doesn't have `capsule-namespace-provisioner` ClusterRoleBinding | `kubectl create clusterrolebinding capsule-<user> --clusterrole=capsule-namespace-provisioner --user=<username>` |
| Capsule webhook doesn't intercept namespace creation | Wrong group used — Capsule v0.13.0 watches group `projectcapsule.dev`, not `capsule.clastix.io` | Use `kubectl --as=<user> --as-group=projectcapsule.dev` |
| Namespace quota not enforced | Capsule v0.13.0 doesn't enforce quotas by default | Patch CapsuleConfiguration: `forceTenantPrefix: true` |
| Namespace name rejected by webhook | With `forceTenantPrefix: true`, names must start with `<tenant-name>-` | Use `team-alpha-frontend` not `frontend` |
| Capsule deprecation warnings on Tenant create | `containerRegistries`, `limitRanges`, `networkPolicies` fields deprecated in v0.13.0 | Fields still work — migrate to `TenantReplication` resources when ready |



---

## Appendix A — Alternative Base Options (kind & Rancher Desktop)

The primary guide uses Lima + K3s (§7). This appendix covers kind and Rancher Desktop for users who prefer those environments. Both have the same MetalLB networking limitations — see §8 for workarounds.

### A.1 kind (Docker Desktop)

**Best for:** Throwaway demos, no VM overhead, fastest setup.

**Limitations:** MetalLB IPs not routable from Mac host (§8), no eBPF/Cilium, upstream K8s not K3s.

```bash
brew install kind helm kubectl
# Docker Desktop must be running
```

```bash
# scripts/setup-kind.sh — or manually:
cat <<EOF | kind create cluster --name kamaji-mgmt --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: kamaji-mgmt
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30001
        hostPort: 7443
        protocol: TCP
      - containerPort: 30080
        hostPort: 8080
        protocol: TCP
EOF

kubectl config use-context kind-kamaji-mgmt
```

Install MetalLB:

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.3/config/manifests/metallb-native.yaml
kubectl rollout status daemonset/speaker -n metallb-system --timeout=120s

GW_IP=$(docker network inspect -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' kind)
NET_IP=$(echo "${GW_IP}" | sed -E 's|^([0-9]+\.[0-9]+)\..*$||g')

cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
    - ${NET_IP}.255.200-${NET_IP}.255.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-l2
  namespace: metallb-system
EOF
```

Then run `./scripts/install-kamaji.sh` — see §7D.

> MetalLB IPs (`172.x.255.x`) are inside Docker's VM — not reachable from your Mac terminal. Use port-forward (§8 Option A) or NodePort mappings (§8 Option D).

---

### A.2 Rancher Desktop (K3s, managed)

**Best for:** Daily dev machine use, wants real K3s with a GUI, minimal config.

**Limitations:** MetalLB same as kind (NAT networking), VMType config less flexible than Lima.

```bash
brew install --cask rancher
brew install helm kubectl
```

Configure via `rdctl`:

```bash
# scripts/setup-rancher.sh — or manually:
rdctl set \
  --kubernetes.enabled=true \
  --kubernetes.version="v1.32.4+k3s1" \
  --container-engine.name=containerd \
  --kubernetes.options.flannel=false \
  --kubernetes.options.traefik=false

# Wait ~60s for restart
until kubectl --context rancher-desktop get nodes --no-headers 2>/dev/null | grep -q Ready; do
  sleep 5
done
kubectl config use-context rancher-desktop
```

Then install MetalLB with the node IP as the pool base:

```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
NET_PREFIX=$(echo "${NODE_IP}" | cut -d. -f1-3)

kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.3/config/manifests/metallb-native.yaml
kubectl rollout status daemonset/speaker -n metallb-system --timeout=120s

cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lima-pool
  namespace: metallb-system
spec:
  addresses:
    - ${NET_PREFIX}.200-${NET_PREFIX}.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: lima-l2
  namespace: metallb-system
EOF
```

Then run `./scripts/install-kamaji.sh` — see §7D.

> Rancher Desktop uses Lima under the hood but in NAT mode — MetalLB IPs have the same routing issues as kind. See §8 for workarounds.


---

## 18. Operational Reference

### Resource footprint per TCP (lab)

| Component | CPU request | Memory request |
|---|---|---|
| kube-apiserver | 100m | 256Mi |
| kube-controller-manager | 100m | 128Mi |
| kube-scheduler | 50m | 64Mi |
| konnectivity-server | 100m | 128Mi |
| **Total per TCP** | **~350m** | **~576Mi** |

A MacBook Pro M3 with 16GB can comfortably run 6–8 TCPs in a kind cluster.

### Useful status queries

```bash
# All TCPs across all namespaces with endpoint and version
kubectl get tcp -A -o wide

# TCP not in Ready state
kubectl get tcp -A -o json | \
  jq '.items[] | select(.status.kubernetesResources.version.status != "Ready") | .metadata.name'

# Datastore health
kubectl get datastore -o wide

# etcd pod health
kubectl get pods -n kamaji-etcd

# Cert expiry for a TCP (cert-manager issued)
kubectl get certificate -n tenant-demo
```

### Certificate management

Kamaji auto-rotates via kubeadm. Manual rotation via plugin:

```bash
kubectl kamaji rotate-certificate --namespace tenant-demo tenant-demo --component apiserver
```

### Backup and restore

Kamaji TCPs back up via standard etcd snapshot (targeting the `kamaji-etcd` StatefulSet) or PostgreSQL PITR if using CloudNativePG. The `TenantControlPlane` CR definition itself should be in Git — it's the source of truth. Etcd/PostgreSQL contains only the runtime state.

```bash
# Snapshot kamaji-etcd (exec into any etcd pod)
kubectl exec -n kamaji-etcd kamaji-etcd-0 -- \
  etcdctl snapshot save /tmp/snap.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/pki/ca.crt \
  --cert=/etc/etcd/pki/server.crt \
  --key=/etc/etcd/pki/server.key

kubectl cp kamaji-etcd/kamaji-etcd-0:/tmp/snap.db ./kamaji-etcd-backup.db
```

### Pausing a TCP (maintenance)

```bash
kubectl annotate tcp tenant-demo -n tenant-demo \
  kamaji.clastix.io/paused=true
```

Kamaji stops reconciling the TCP. Resume by removing the annotation.

### Tenant cluster version support matrix

Kamaji supports Kubernetes versions within the standard N-3 skew from the management cluster version. Running a 1.32 management cluster:

| Tenant version | Supported |
|---|---|
| v1.33 | ✅ |
| v1.32 | ✅ |
| v1.31 | ✅ |
| v1.30 | ✅ |
| v1.29 | ⚠️ best-effort |

---

## Quick Reference — Core Commands

```bash
# Management
kubectl get tcp -A                                      # all tenant control planes
kubectl get datastore                                  # datastores
kubectl describe tcp <name> -n <ns>                    # events + status
kubectl kamaji kubeconfig -n <ns> <name>               # get admin kubeconfig
kubectl kamaji join-token -n <ns> <name>               # worker join command

# Helm repos
helm repo add clastix https://clastix.github.io/charts
helm repo add jetstack https://charts.jetstack.io

# Port-forward console
kubectl port-forward svc/console-kamaji-console 8080:80 -n kamaji-system

# Context switch to tenant
export KUBECONFIG=/tmp/tenant-demo.kubeconfig
kubectl get nodes
kubectl get pods -A
```

---

*Kamaji docs: [kamaji.clastix.io](https://kamaji.clastix.io) | GitHub: [clastix/kamaji](https://github.com/clastix/kamaji)*
