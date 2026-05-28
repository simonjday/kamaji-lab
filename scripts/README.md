# Kamaji Lab Scripts

Companion scripts for the Kamaji overview guide.

## Quick start

Pick your base (kind, Rancher Desktop, or Lima), then run the common Kamaji install.

### Option A — kind (Docker Desktop, quickest)

```bash
chmod +x scripts/*.sh
./scripts/setup-kind.sh
./scripts/setup-metallb-kind.sh
./scripts/install-kamaji.sh
```

> MetalLB IPs are NOT directly routable from macOS. See Section 8 of the guide for workarounds.

---

### Option B — Rancher Desktop (real K3s, managed VM)

```bash
chmod +x scripts/*.sh
./scripts/setup-rancher.sh          # configures rdctl for K3s
./scripts/setup-cilium.sh           # eBPF CNI (Flannel disabled)
./scripts/setup-metallb-lima.sh     # MetalLB — IPs directly routable
./scripts/install-kamaji.sh
```

---

### Option C — Lima + K3s (full control, best for GitOps/CI)

```bash
chmod +x scripts/*.sh
./scripts/setup-lima-k3s.sh         # creates and configures the VM
export KUBECONFIG=~/.kube/k3s-kamaji.kubeconfig
./scripts/setup-cilium.sh           # eBPF CNI
./scripts/setup-metallb-lima.sh     # MetalLB — IPs directly routable
./scripts/install-kamaji.sh
```

---

## Get tenant kubeconfig

After creating a TenantControlPlane:

```bash
./scripts/get-tenant-kubeconfig.sh tenant-demo tenant-demo
```

Auto-detects whether the TCP endpoint is directly reachable (socket_vmnet) or behind NAT (usernet) and gives you the right export command either way.

## Teardown

```bash
./scripts/teardown.sh kind kamaji-mgmt   # remove kind cluster
./scripts/teardown.sh lima kamaji-k3s    # delete Lima VM
./scripts/teardown.sh rancher            # reset Rancher Desktop
```

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `CLUSTER_NAME` | `kamaji-mgmt` | kind cluster name |
| `LOCAL_PORT` | `7443` | Port for tenant kubeconfig port-forward |
| `VM_NAME` | `kamaji-k3s` | Lima VM name |
| `K3S_VERSION` | `v1.32.4+k3s1` | K3s version for Lima/Rancher |
| `CPU` | `4` | Lima VM CPU count |
| `MEMORY` | `8GiB` | Lima VM memory |
| `DISK` | `40GiB` | Lima VM disk |
