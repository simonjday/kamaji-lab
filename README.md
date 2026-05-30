# Kamaji Platform Engineering Lab

> A fully validated platform engineering lab — Kamaji hosted control planes, Capsule multi-tenancy, and Kamaji Console on macOS Apple Silicon using kind.

---

## What This Is

A hands-on lab demonstrating:

- **Kamaji** — hosted Kubernetes control planes (TCPs) running as pods
- **Capsule** — soft multi-tenancy with namespace quotas, RBAC delegation, and policy enforcement
- **Kamaji Console** — web dashboard for managing tenant control planes
- **Kind** — management cluster running in Docker, no VMs needed
- **Docker container workers** — worker nodes in the same Docker network, no bridging required

Validated on macOS M3 Apple Silicon. Every error encountered is documented.

---

## Architecture

```
macOS M3
  └── Docker Desktop
        ├── kind cluster: kamaji-mgmt (K8s v1.34)
        │     ├── Kamaji Operator + etcd (3-node)
        │     ├── MetalLB (172.18.255.200-250)
        │     ├── cert-manager + Gateway API CRDs
        │     └── Kamaji Console
        │
        └── Docker container: kamaji-worker-01
              └── kubelet → TenantControlPlane (tenant-demo)

Tenant access: kubectl port-forward :7443 → 172.18.255.200:6443
```

---

## Quick Start

```bash
git clone https://github.com/simonjday/kamaji-lab
cd kamaji-lab && chmod +x scripts/*.sh

# Source shell helpers (do this once)
echo 'source "$(pwd)/scripts/shell-helpers.zsh"' >> ~/.zshrc && source ~/.zshrc

# 1. Management cluster
./scripts/setup-kind-kamaji.sh
kind export kubeconfig --name kamaji-mgmt
export KUBECONFIG=~/.kube/config
kubectl get nodes

# 2. Tenant control plane
kubectl create namespace tenant-demo
kubectl apply -f manifests/tenants/tenant-demo.yaml
kubectl get tcp -n tenant-demo -w

# 3. Extract tenant kubeconfig
kubectl get secret tenant-demo-admin-kubeconfig \
  -n tenant-demo -o jsonpath='{.data.admin\.conf}' | base64 -d \
  > ~/.kube/tenant-demo.kubeconfig
sed 's|https://172.18.255.200:6443|https://127.0.0.1:7443|g' \
  ~/.kube/tenant-demo.kubeconfig > ~/.kube/tenant-demo-local.kubeconfig

# 4. Join worker node  [management cluster context]
export KUBECONFIG=~/.kube/config
./scripts/setup-worker-kind.sh tenant-demo tenant-demo

# 5. Install Capsule   [tenant cluster]
./scripts/setup-capsule.sh ~/.kube/tenant-demo-local.kubeconfig

# 6. Install Kamaji Console  [management cluster]
export KUBECONFIG=~/.kube/config
./scripts/setup-kamaji-console.sh
kamaji-ui
```

---

## Shell Helpers

After sourcing `scripts/shell-helpers.zsh`:

```bash
use-mgmt                       # switch to management cluster
use-tenant tenant-demo         # switch to tenant (starts port-forward)
kamaji-status                  # TCP list + pod health + worker containers
kamaji-ui                      # open Kamaji Console in browser
recover-worker tenant-demo     # rebuild kube-proxy after Docker restart
reset-tenant tenant-demo       # clear kubeconfig cache
```

---

## Capsule Multi-Tenancy Demo

```bash
use-tenant tenant-demo

# Alice creates namespaces (quota: 3, prefix enforced)
kubectl --as=alice --as-group=projectcapsule.dev create namespace team-alpha-frontend
kubectl --as=alice --as-group=projectcapsule.dev create namespace team-alpha-backend
kubectl --as=alice --as-group=projectcapsule.dev create namespace team-alpha-data

# 4th blocked by quota
kubectl --as=alice --as-group=projectcapsule.dev create namespace team-alpha-overflow
# Error: Cannot exceed Namespace quota

# Bob's namespaces isolated from Alice's
kubectl --as=bob --as-group=projectcapsule.dev get pods -n team-alpha-frontend
# Error: Forbidden
```

---

## Scripts

| Script | Purpose |
|---|---|
| `setup-kind-kamaji.sh` | Management cluster: kind + MetalLB + cert-manager + Gateway API CRDs + Kamaji |
| `setup-worker-kind.sh` | Docker container worker joined to a TCP |
| `setup-capsule.sh` | Capsule on tenant cluster + demo tenants |
| `setup-kamaji-console.sh` | Kamaji Console on management cluster |
| `teardown.sh` | Full or partial teardown |
| `shell-helpers.zsh` | `use-mgmt`, `use-tenant`, `recover-worker`, `kamaji-status`, `kamaji-ui` |

---

## Component Versions

| Component | Version |
|---|---|
| macOS | 15 (Apple M3) |
| Docker Desktop | 4.x |
| kind | v0.20+ |
| Management K8s | v1.34.0 |
| Tenant K8s | v1.30.2 |
| Kamaji | v1.0.0 |
| Kamaji Console | v0.2.1 |
| Capsule | v0.13.0 |
| cert-manager | v1.20.2 |
| MetalLB | v0.15.3 |
| CNI plugins | v1.5.1 |

---

## Documentation

| Doc | Contents |
|---|---|
| [docs/kamaji-setup-guide.md](docs/kamaji-setup-guide.md) | Installation reference, architecture, prerequisites, known issues |
| [docs/kamaji-operations.md](docs/kamaji-operations.md) | Worker recovery, quota management, multiple TCPs, teardown, troubleshooting |
| [docs/kamaji-demo-flows.md](docs/kamaji-demo-flows.md) | 10 advanced demo scenarios: Capsule, GitOps, Observability |

---

## References

- [Kamaji docs](https://kamaji.clastix.io)
- [Capsule docs](https://projectcapsule.dev)
- [Kamaji kind guide](https://github.com/clastix/kamaji/blob/master/docs/content/getting-started/kamaji-kind.md)

---

## Author

Simon Day | Platform & DevOps Engineer
Kubernetes, GitOps, Confluent Platform

*Built on macOS M3, May 2026.*
