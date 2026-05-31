# Running Three Kubernetes Clusters on Your MacBook — A Platform Engineering Lab with Kamaji

*How I built a fully multi-tenant Kubernetes platform on Apple Silicon using hosted control planes, GitOps, and soft multi-tenancy — all without a single VM.*

---

## The Problem with "Playing" Kubernetes

If you work in platform engineering, you know the frustration. You want to demo hosted control planes, test multi-tenancy policies, or validate a GitOps pipeline — but standing up a real multi-cluster environment means cloud costs, slow provisioning, or wrestling with local VM tooling that breaks after every macOS update.

I wanted a setup that:
- Ran entirely on my MacBook Pro M3
- Had real worker nodes, not just a single-node kind cluster
- Demonstrated genuine multi-tenancy with Capsule
- Could be torn down and rebuilt in under 10 minutes

What I ended up with was a full platform engineering lab using **Kamaji** — and it runs three Kubernetes clusters simultaneously on a laptop.

---

## What is Kamaji?

[Kamaji](https://kamaji.clastix.io) is a Kubernetes operator from Clastix that runs Tenant Control Planes (TCPs) as pods inside a management cluster. Instead of provisioning a VM per cluster, the API server, controller manager, scheduler, and konnectivity components all run as containers. Worker nodes join a TCP exactly like a normal cluster.

The result: you can run dozens of isolated Kubernetes control planes on a single host, each with their own RBAC, namespaces, and workloads — sharing only the underlying etcd and node infrastructure.

---

## The Architecture

```
macOS M3
  └── Docker Desktop
        ├── kind cluster: kamaji-mgmt (K8s v1.34)
        │     ├── Kamaji Operator + etcd (3-node)
        │     ├── MetalLB (172.18.255.200-250)
        │     ├── cert-manager + Gateway API CRDs
        │     └── Kamaji Console (web UI)
        │
        └── Docker containers: kamaji-worker-01, kamaji-worker-02
              └── kubelet → TenantControlPlane
                    ├── Flannel CNI
                    ├── CoreDNS
                    ├── konnectivity-agent
                    └── Capsule + ArgoCD + Prometheus
```

The key insight: worker nodes are Docker containers using the `kindest/node` image, running in the same Docker network as the kind management cluster. MetalLB assigns real IPs to each TCP's LoadBalancer service, and those IPs are directly reachable from any container in the `kind` Docker network — no port-forwarding, no VM bridging.

---

## Quick Start

Everything is scripted. From zero to a working three-cluster environment with multi-tenancy:

```bash
git clone https://github.com/simonjday/kamaji-lab
cd kamaji-lab && chmod +x scripts/*.sh

./scripts/setup-kind-kamaji.sh
kind export kubeconfig --name kamaji-mgmt

kubectl create namespace tenant-demo
kubectl apply -f manifests/tenants/tenant-demo.yaml
kubectl get tcp -n tenant-demo -w

./scripts/setup-worker-kind.sh tenant-demo tenant-demo
./scripts/setup-capsule.sh ~/.kube/tenant-demo-local.kubeconfig
./scripts/setup-kamaji-console.sh
```

That's it. The TCP goes Ready in about 20 seconds. The worker joins in under 2 minutes.

---

## What You Get

### Kamaji Console

A web dashboard showing all your Tenant Control Planes with status, endpoint, version, and datastore information. Create and manage TCPs without touching kubectl.

### Capsule Multi-Tenancy

[Capsule](https://projectcapsule.dev) adds soft multi-tenancy on top of the tenant cluster. Each team gets a namespace group with quotas, prefix enforcement, and RBAC delegation:

```bash
# Alice can create namespaces with her team prefix
kubectl --as=alice --as-group=projectcapsule.dev \
  create namespace team-alpha-frontend   # ✅ Created

# 4th namespace blocked by quota
kubectl --as=alice --as-group=projectcapsule.dev \
  create namespace team-alpha-overflow   # ❌ Cannot exceed Namespace quota

# Bob cannot access Alice's namespaces
kubectl --as=bob --as-group=projectcapsule.dev \
  get pods -n team-alpha-frontend        # ❌ Forbidden
```

### GitOps with ArgoCD

ArgoCD on the management cluster manages TCP manifests from Git — push a new TCP manifest, it provisions within 3 minutes. Delete the manifest, ArgoCD prunes the cluster. Full TCP-as-code.

ArgoCD on the tenant cluster deploys workloads into Capsule tenant namespaces. An ApplicationSet automatically generates one ArgoCD Application per Capsule namespace — add a namespace to Git, ArgoCD handles the rest.

### Observability

Prometheus and Grafana on both clusters:
- **Tenant cluster:** kube-state-metrics, pod/deployment metrics via Grafana
- **Management cluster:** Kamaji etcd monitoring — all 3 etcd nodes scraped, leader status, DB size, proposal rates

---

## The Interesting Gotchas

This wasn't a smooth setup. Here are the three things that cost the most time:

### 1. Kamaji requires Gateway API CRDs

The latest Kamaji operator watches `TLSRoute` resources from the experimental Gateway API channel. Install these before Kamaji or the controller crashes with:

```
failed to wait for tenantcontrolplane caches to sync: 
  no matches for kind "TLSRoute" in version "gateway.networking.k8s.io/v1alpha2"
```

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/experimental-install.yaml
```

### 2. kubeadm join doesn't work with Kamaji TCPs

Kamaji TCPs don't create the `cluster-info` ConfigMap that kubeadm token discovery requires. Every tutorial showing `kubeadm join` will fail silently then time out. You have to configure the kubelet directly via a `bootstrap-kubelet.conf` with a bootstrap token — the scripts handle this, but it took considerable debugging to figure out.

### 3. Capsule quota reconciliation lag

Capsule v0.13.0 has a reconciliation lag between namespace creation and `status.size` update. The admission webhook reads `status.size` for quota checks — if it's stale, the 4th namespace gets created when it shouldn't. Fix: restart the Capsule controller after install or after any quota change.

```bash
kubectl rollout restart deployment/capsule-controller-manager -n capsule-system
```

There are 15 more documented gotchas in the repo's known issues table — everything from IPv4/IPv6 gateway detection bugs in MetalLB pool creation to kube-proxy needing a kubeconfig that Kamaji doesn't create automatically.

---

## The Demo Flows

The repo includes 10 validated demo scenarios:

1. **Capsule ResourceQuota enforcement** — exhaust the pod limit across namespaces
2. **Capsule registry allow-list** — block unauthorised container registries
3. **Capsule Proxy** — tenant-scoped kubectl (OIDC architecture documented)
4. **TCP replica scaling** — Kamaji rolling control plane updates
5. **Second tenant cluster** — two isolated clusters side by side
6. **ArgoCD TCP-as-code** — manage TCPs from Git on the management cluster
7. **ArgoCD on tenant cluster** — deploy workloads via GitOps into Capsule namespaces
8. **ApplicationSet per Capsule tenant** — one ArgoCD app auto-generated per namespace
9. **Prometheus + Grafana on tenant cluster** — workload metrics, deployment tracking
10. **Kamaji etcd monitoring** — all 3 etcd nodes scraped, key metrics in Grafana Explore

Each scenario has working commands, expected output, known limitations, and a reset section to return to a clean state.

---

## Why This Matters for Platform Engineering

The conventional wisdom is that you need cloud infrastructure to demonstrate platform engineering properly. Kamaji challenges that — the control plane separation it demonstrates (management cluster vs tenant cluster vs worker nodes) is exactly the architecture pattern used in production hosted Kubernetes offerings.

Running this locally means you can:
- Demo the full lifecycle (provision → deploy → monitor → decommission) in a meeting
- Test Capsule policy changes without touching production
- Experiment with GitOps patterns for cluster management
- Show new team members the platform architecture without cloud costs

The setup takes under 10 minutes from scratch. Teardown is one command.

---

## Get the Repo

Everything is at [github.com/simonjday/kamaji-lab](https://github.com/simonjday/kamaji-lab).

The repo includes:
- **kamaji-setup-guide.md** — full installation reference with known issues
- **kamaji-operations.md** — day 2 ops: worker recovery, quota management, multiple TCPs
- **kamaji-demo-flows.md** — all 10 demo scenarios with validated steps

---

*Simon Day is a Platform & DevOps Engineer specialising in Kubernetes, GitOps, and Confluent Platform.*
