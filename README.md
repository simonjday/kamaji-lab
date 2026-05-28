# Kamaji Platform Engineering Lab

> A practitioner's guide to building a multi-tenant Kubernetes platform on macOS using K3s, Kamaji, Capsule, and Kamaji Console — fully scripted and documented from real lab sessions.

![Kamaji Console](docs/images/kamaji-console-dashboard.png)

---

## What This Is

This repo contains a complete how-to guide and automation scripts for running a production-pattern Kubernetes platform on a MacBook Pro (Apple Silicon). Every step was validated hands-on — including all the errors, fixes, and gotchas documented along the way.

**The stack:**

| Layer | Tool | Purpose |
|---|---|---|
| Management cluster | K3s via Lima VM | Lightweight Linux K3s on macOS |
| Hosted control planes | Kamaji | Run tenant Kubernetes clusters as pods |
| Soft multi-tenancy | Capsule | Namespace groups, quotas, RBAC per team |
| Networking | Flannel | CNI for tenant worker nodes |
| Load balancer | MetalLB | LoadBalancer service IPs for TCP endpoints |
| Web UI | Kamaji Console | Dashboard for managing tenant control planes |
| Certs | cert-manager | TLS for Kamaji etcd and Capsule webhooks |

---

## Architecture

```
macOS M3 (your laptop)
  └── Lima VM (Ubuntu 24.04, vmType: vz)
        └── K3s v1.35 — Management Cluster
              ├── Kamaji Operator
              ├── kamaji-etcd (3-node StatefulSet)
              ├── MetalLB (pool: 192.168.5.200-250)
              ├── Kamaji Console (web UI)
              └── TenantControlPlane: tenant-demo (v1.32.0)
                    └── 4 containers: apiserver, scheduler, controller-manager, konnectivity

Multipass VM (Ubuntu 22.04, worker-01)
  └── kubelet v1.32 joined to tenant-demo
        ├── Flannel CNI
        ├── CoreDNS
        └── konnectivity-agent

Port-forwards (Mac host — required while cluster is in use):
  :7443   → TCP:6443  (kubectl access)
  :16443  → TCP:6443  (kubelet, 0.0.0.0)
  :6443   → TCP:6443  (ClusterIP routing, Multipass gateway)
  :8132   → TCP:8132  (konnectivity tunnel, Multipass gateway)
```

---

## Tested On

| Component | Version |
|---|---|
| macOS | 15 (Apple M3) |
| Lima | 2.1.1 |
| K3s | v1.35.5+k3s1 |
| Kamaji | v0.x (chart 0.0.0+latest) |
| Kamaji Console | v0.2.1 (chart 0.1.3) |
| Capsule | v0.13.0 |
| cert-manager | v1.17+ |
| MetalLB | v0.15.3 |
| Multipass | latest |

---

## Prerequisites

```bash
brew install lima helm kubectl multipass
```

---

## Quick Start

```bash
git clone https://github.com/<your-username>/kamaji-lab
cd kamaji-lab
chmod +x scripts/*.sh

# 1. Create Lima K3s management cluster
./scripts/setup-lima-k3s.sh
export KUBECONFIG=~/.kube/k3s-kamaji.kubeconfig

# 2. MetalLB + Kamaji
./scripts/setup-metallb-lima.sh
./scripts/install-kamaji.sh

# 3. Create a tenant control plane
kubectl create namespace tenant-demo
kubectl apply -f manifests/tenants/tenant-demo.yaml

# 4. Extract kubeconfig and set up port-forwards
./scripts/get-tenant-kubeconfig.sh tenant-demo tenant-demo

# 5. Source shell helpers
echo 'source "$(pwd)/scripts/shell-helpers.zsh"' >> ~/.zshrc
source ~/.zshrc

# Switch between clusters
use-mgmt           # management cluster
use-tenant tenant-demo  # tenant cluster (starts all port-forwards)
```

---

## What's Covered

### Core Guide (`docs/kamaji-overview.md`)

| Section | Topic |
|---|---|
| §1–6 | Kamaji architecture, CRDs, datastores, Konnectivity, CAPI |
| §7 | Lima + K3s setup on macOS (tested path) |
| §8 | macOS MetalLB networking workarounds |
| §9 | Provisioning tenant clusters, upgrades, multi-version |
| §10 | Joining worker nodes via Multipass |
| §11 | Kamaji Console web UI |
| §12 | GitOps with ArgoCD ApplicationSets |
| §13 | Capsule multi-tenancy — tenants, quotas, workloads, kubectl access |
| §14 | Layered architecture: Kamaji + Capsule together |
| §15 | K3s reference |
| §16 | Cilium eBPF networking |
| §17 | Operational reference |
| §18 | Known issues and API changes (all errors encountered documented) |
| Appendix A | Alternative bases: kind and Rancher Desktop |

### Scripts (`scripts/`)

| Script | Does |
|---|---|
| `setup-lima-k3s.sh` | Creates Lima VM, installs K3s (handles unattended-upgrades, vmType: vz) |
| `setup-metallb-lima.sh` | Installs MetalLB with correct pool for Lima networking |
| `install-kamaji.sh` | cert-manager + Kamaji, auto-detects context |
| `get-tenant-kubeconfig.sh` | Extracts TCP admin kubeconfig, detects NAT vs direct routing |
| `setup-worker-node.sh` | Full Multipass worker node setup (containerd, kubelet, Flannel, all fixes) |
| `setup-capsule.sh` | cert-manager + Capsule on tenant cluster, demo Tenant + RBAC |
| `setup-kamaji-console.sh` | Kamaji Console with correct secret keys |
| `shell-helpers.zsh` | `use-mgmt`, `use-tenant`, `kamaji-ui`, `kamaji-status`, `reset-tenant` |
| `teardown.sh` | Clean removal of Lima VM, Multipass VM, or Rancher Desktop |

### Shell Helpers

After sourcing `scripts/shell-helpers.zsh`:

```bash
use-mgmt                    # switch to management cluster
use-tenant tenant-demo      # switch to tenant (starts all 4 port-forwards)
kamaji-status               # TCP list + pod health
kamaji-ui                   # open Kamaji Console in browser
reset-tenant tenant-demo    # clear kubeconfig cache
```

---

## Known Issues

See **§18** of the guide for the full table of every error hit during this lab, with causes and fixes. Headlines:

- Lima requires `vmType: vz` on Apple Silicon (not qemu)
- Kamaji API uses `spec.dataStore` not `spec.dataStoreName`
- Capsule webhook group is `projectcapsule.dev` not `capsule.clastix.io`
- `forceTenantPrefix: true` required for Capsule quota enforcement
- Worker nodes need iptables-legacy, br_netfilter, and DNS stub disabled (all handled by `setup-worker-node.sh`)
- All four port-forwards must stay running for a healthy tenant cluster

---

## Repo Structure

```
kamaji-lab/
├── README.md
├── docs/
│   ├── kamaji-overview.md      # main guide (~3000 lines)
│   └── images/
│       └── kamaji-console-dashboard.png
├── scripts/
│   ├── shell-helpers.zsh
│   ├── setup-lima-k3s.sh
│   ├── setup-metallb-lima.sh
│   ├── install-kamaji.sh
│   ├── get-tenant-kubeconfig.sh
│   ├── setup-worker-node.sh
│   ├── setup-capsule.sh
│   ├── setup-kamaji-console.sh
│   ├── setup-kind.sh           # Appendix A
│   ├── setup-rancher.sh        # Appendix A
│   └── teardown.sh
└── manifests/
    └── tenants/
        └── tenant-demo.yaml
```

---

## References

- [Kamaji docs](https://kamaji.clastix.io)
- [Kamaji GitHub](https://github.com/clastix/kamaji)
- [Capsule docs](https://projectcapsule.dev)
- [Lima](https://lima-vm.io)
- [MetalLB](https://metallb.universe.tf)
- Medium article: [Modern Kubernetes Platform Engineering](https://medium.com/write-a-catalyst/modern-kubernetes-platform-engineering-d6a9fd96b9bf)

---

## Author

Simon Day — Senior Engineering Manager, Accenture  
Platform & DevOps Engineer | Kubernetes, GitOps, Confluent Platform

*Built and documented on a MacBook Pro M3, May 2026.*
