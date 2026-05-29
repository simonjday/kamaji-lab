# Kamaji Platform Lab — Advanced Demo Flows

> **Prerequisites:** Quick start complete — management cluster running, `tenant-demo` TCP Ready, `worker-01` joined, Capsule installed with `team-alpha` and `team-beta` tenants, Kamaji Console accessible.
>
> All commands assume you have sourced `scripts/shell-helpers.zsh`.

---

## Table of Contents

1. [Capsule — ResourceQuota Enforcement](#1-capsule--resourcequota-enforcement)
2. [Capsule — Registry Allow-List](#2-capsule--registry-allow-list)
3. [Capsule Proxy — Tenant-Scoped kubectl](#3-capsule-proxy--tenant-scoped-kubectl)
4. [Kamaji — TCP In-Place Upgrade](#4-kamaji--tcp-in-place-upgrade)
5. [Kamaji — Second Tenant Cluster](#5-kamaji--second-tenant-cluster)
6. [GitOps — ArgoCD on Management Cluster (TCP-as-Code)](#6-gitops--argocd-on-management-cluster-tcp-as-code)
7. [GitOps — ArgoCD on Tenant Cluster](#7-gitops--argocd-on-tenant-cluster)
8. [GitOps — ApplicationSet per Capsule Tenant](#8-gitops--applicationset-per-capsule-tenant)
9. [Observability — Prometheus + Grafana on Tenant Cluster](#9-observability--prometheus--grafana-on-tenant-cluster)
10. [Observability — Kamaji etcd Monitoring](#10-observability--kamaji-etcd-monitoring)

---

## 1. Capsule — ResourceQuota Enforcement

**Goal:** Show that aggregate resource usage across all tenant namespaces is capped at the tenant level.

**Setup:** `team-alpha` has `pods: 20` quota across all its namespaces.

```bash
use-tenant tenant-demo

# Deploy pods into team-alpha-frontend until quota is exhausted
for i in $(seq 1 22); do
  kubectl --as=alice --as-group=projectcapsule.dev apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: load-pod-${i}
  namespace: team-alpha-frontend
spec:
  containers:
  - name: nginx
    image: nginx:alpine
    resources:
      requests:
        cpu: 10m
        memory: 16Mi
EOF
  echo "Created pod ${i}"
done
```

**Expected output:** Around pod 21-22 you will see:

```
Error from server (Forbidden): pods "load-pod-21" is forbidden:
exceeded quota: capsule-team-alpha-..., requested: pods=1, used: pods=20, limited: pods=20
```

**Verify quota usage:**

```bash
kubectl get resourcequota -n team-alpha-frontend
# Shows current pod count vs limit

# Quota applies tenant-wide across ALL team-alpha namespaces
kubectl get resourcequota -A | grep team-alpha
```

**Cleanup:**

```bash
for i in $(seq 1 22); do
  kubectl delete pod load-pod-${i} -n team-alpha-frontend 2>/dev/null || true
done
```

---

## 2. Capsule — Registry Allow-List

**Goal:** Show that pods using unauthorised container registries are blocked at admission.

**Note:** The `containerRegistries` field is deprecated in Capsule v0.13.0 but still functional. It will be replaced by `TenantReplication` in a future release.

**Setup:** Patch `team-alpha` to only allow `docker.io` and `registry.k8s.io`:

```bash
use-tenant tenant-demo

kubectl patch tenant team-alpha --type=merge -p '{
  "spec": {
    "containerRegistries": {
      "allowed": ["docker.io", "registry.k8s.io"],
      "allowedRegex": ""
    }
  }
}'

# Force reconciliation
kubectl rollout restart deployment/capsule-controller-manager -n capsule-system
kubectl rollout status deployment/capsule-controller-manager -n capsule-system
```

**Demo — allowed registry works:**

```bash
kubectl --as=alice --as-group=projectcapsule.dev apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: allowed-pod
  namespace: team-alpha-frontend
spec:
  containers:
  - name: nginx
    image: docker.io/nginx:alpine
    resources:
      requests:
        cpu: 10m
        memory: 16Mi
EOF
# Created successfully
```

**Demo — blocked registry fails:**

```bash
kubectl --as=alice --as-group=projectcapsule.dev apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: blocked-pod
  namespace: team-alpha-frontend
spec:
  containers:
  - name: app
    image: ghcr.io/some/private-image:latest
    resources:
      requests:
        cpu: 10m
        memory: 16Mi
EOF
# Error: Container image ghcr.io/some/private-image:latest not in the registry allow-list
```

**Cleanup:**

```bash
kubectl delete pod allowed-pod -n team-alpha-frontend 2>/dev/null || true
kubectl patch tenant team-alpha --type=json \
  -p '[{"op":"remove","path":"/spec/containerRegistries"}]'
```

---

## 3. Capsule Proxy — Tenant-Scoped kubectl

**Goal:** Show that tenant users see only their own namespaces when using `kubectl get namespaces`.

> **Lab limitation:** Capsule Proxy is designed for OIDC-authenticated users — JWT tokens from an identity provider (Keycloak, Dex, etc.) are mapped to Capsule tenant owners. In this kind lab without OIDC, the proxy receives ServiceAccount tokens which land in the `system:serviceaccounts` group rather than `projectcapsule.dev`, so namespace filtering doesn't apply.
>
> **For a complete Capsule Proxy demo** you would need: Keycloak or Dex → users authenticate → JWT issued → proxy maps JWT `preferred_username` claim to Capsule tenant owner → `kubectl get namespaces` returns filtered list.
>
> **What works in this lab:** Use `--as` impersonation to demonstrate the filtering concept.

**Install Capsule Proxy:**

```bash
use-tenant tenant-demo

# cert-manager must be installed first (already done by setup-capsule.sh)
# Use generateCertificates=false — the certgen job has permission issues in this setup
helm install capsule-proxy projectcapsule/capsule-proxy \
  --namespace capsule-system \
  --set replicaCount=1 \
  --set "options.generateCertificates=false" \
  --set "certManager.certificate.create=true"

kubectl get pods -n capsule-system | grep proxy
# capsule-proxy-xxx   1/1   Running
```

**Access via port-forward:**

```bash
kubectl port-forward -n capsule-system svc/capsule-proxy 9001:9001 &
sleep 2
```

**Create a ServiceAccount for alice and generate a token:**

```bash
# Create ServiceAccount for alice in the tenant cluster
kubectl create serviceaccount alice -n team-alpha-frontend 2>/dev/null || true

# Bind to capsule provisioner so alice has tenant permissions
kubectl create clusterrolebinding alice-sa-provisioner \
  --clusterrole=capsule-namespace-provisioner \
  --serviceaccount=team-alpha-frontend:alice 2>/dev/null || true

# Generate a 24h token
ALICE_TOKEN=$(kubectl create token alice -n team-alpha-frontend --duration=24h)

# Create alice's kubeconfig pointing at the proxy
cat > ~/.kube/alice-proxy.kubeconfig << EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    insecure-skip-tls-verify: true
    server: https://127.0.0.1:9001
  name: capsule-proxy
contexts:
- context:
    cluster: capsule-proxy
    user: alice
  name: alice@capsule-proxy
current-context: alice@capsule-proxy
users:
- name: alice
  user:
    token: ${ALICE_TOKEN}
EOF
```

**Lab demo — namespace isolation via impersonation:**

```bash
# alice can only see team-alpha namespaces (Capsule filters via admission webhook)
kubectl --as=alice --as-group=projectcapsule.dev get namespaces   -l capsule.clastix.io/tenant=team-alpha
# NAME                  STATUS   AGE
# team-alpha-backend    Active   1h
# team-alpha-data       Active   1h
# team-alpha-frontend   Active   1h

# alice cannot see team-beta namespaces
kubectl --as=alice --as-group=projectcapsule.dev get pods -n team-beta-api
# Error from server (Forbidden)

# Without --as-group=projectcapsule.dev, alice gets no filtering
kubectl --as=alice get namespaces
# Error: Forbidden (no Capsule group — not a tenant user)
```

**Production Capsule Proxy flow (requires OIDC):**

```
User → kubectl → Capsule Proxy (:9001)
                      ↓ validates JWT, extracts username
                      ↓ maps to Capsule tenant owner
                      ↓ filters namespace list to tenant only
                      → Kubernetes API server
```

Install for future OIDC integration:

```bash
helm upgrade capsule-proxy projectcapsule/capsule-proxy \
  --namespace capsule-system \
  --set replicaCount=1 \
  --set "options.generateCertificates=false" \
  --set "certManager.certificate.create=true" \
  --set "options.oidcUsernameClaim=preferred_username"
```

**Reset after demo:**

```bash
# Uninstall Capsule Proxy
helm uninstall capsule-proxy -n capsule-system

# Remove ServiceAccount and bindings created for the demo
kubectl delete serviceaccount alice -n team-alpha-frontend 2>/dev/null || true
kubectl delete clusterrolebinding alice-sa-provisioner 2>/dev/null || true

# Remove alice as ServiceAccount owner from team-alpha tenant
kubectl patch tenant team-alpha --type=json -p '[{"op": "remove", "path": "/spec/owners/1"}]'

# Remove alice proxy kubeconfig
rm -f ~/.kube/alice-proxy.kubeconfig

# Verify clean state
kubectl get pods -n capsule-system
kubectl get tenants
```

---

## 4. Kamaji — TCP In-Place Upgrade

**Goal:** Demonstrate Kamaji upgrading a tenant Kubernetes version with zero downtime to the control plane.

> **Constraint:** With kind v1.34 management cluster and current Kamaji, supported TCP versions top out at v1.30.x. This demo upgrades within the supported range.

**Check current version:**

```bash
use-mgmt
kubectl get tcp tenant-demo -n tenant-demo
# VERSION   INSTALLED VERSION   STATUS
# v1.30.2   v1.30.2             Ready
```

**Trigger the upgrade:**

```bash
kubectl patch tcp tenant-demo -n tenant-demo --type=merge \
  -p '{"spec":{"kubernetes":{"version":"v1.30.9"}}}'

# Watch Kamaji roll the control plane
kubectl get tcp -n tenant-demo -w
# STATUS goes: Ready → Upgrading → Ready
# Takes ~30-60 seconds

kubectl get pods -n tenant-demo -w
# Old pod terminated, new pod starts with v1.30.9 images
```

**Verify from tenant cluster:**

```bash
use-tenant tenant-demo
kubectl version
# Server Version: v1.30.9

kubectl get nodes
# worker-01 still Ready — worker upgrade is separate and done via drain/rejoin
```

> **Note:** The worker node continues running the previous kubelet version after a TCP upgrade. Worker node upgrades require draining the node, deleting the container, and rejoining with the new version.

---

## 5. Kamaji — Second Tenant Cluster

**Goal:** Show multiple isolated tenant control planes running simultaneously on the same management cluster.

**Create the second TCP:**

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
# Both tenant-demo and tenant-beta show Ready
```

**View in Kamaji Console:**

```bash
kamaji-ui
# Dashboard shows two TCPs with their own endpoints and datastores
```

**Connect to tenant-beta:**

```bash
kubectl get secret tenant-beta-admin-kubeconfig \
  -n tenant-beta -o jsonpath='{.data.admin\.conf}' | base64 -d \
  > ~/.kube/tenant-beta.kubeconfig

# Get tenant-beta endpoint
BETA_EP=$(kubectl get tcp tenant-beta -n tenant-beta \
  -o jsonpath='{.status.controlPlaneEndpoint}')

sed "s|https://${BETA_EP}|https://127.0.0.1:7444|g" \
  ~/.kube/tenant-beta.kubeconfig > ~/.kube/tenant-beta-local.kubeconfig

kubectl port-forward svc/tenant-beta -n tenant-beta 7444:6443 &
export KUBECONFIG=~/.kube/tenant-beta-local.kubeconfig
kubectl get namespaces
```

**Join a second worker to tenant-beta:**

```bash
export KUBECONFIG=~/.kube/config
./scripts/setup-worker-kind.sh tenant-beta tenant-beta kamaji-worker-beta-01
```

**Show isolation:**

```bash
# tenant-demo worker
export KUBECONFIG=~/.kube/tenant-demo-local.kubeconfig
kubectl get nodes
# worker-01

# tenant-beta worker
export KUBECONFIG=~/.kube/tenant-beta-local.kubeconfig
kubectl get nodes
# worker-beta-01 — completely isolated
```

---

## 6. GitOps — ArgoCD on Management Cluster (TCP-as-Code)

**Goal:** Manage TenantControlPlane resources from Git using ArgoCD on the management cluster.

**Install ArgoCD:**

```bash
use-mgmt

kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl rollout status deployment/argocd-server -n argocd --timeout=120s

# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo ""

# Port-forward ArgoCD UI
kubectl port-forward svc/argocd-server -n argocd 8888:443 &
open https://localhost:8888
# Login: admin / <password above>
```

**Create a GitOps structure in your repo:**

```
manifests/
  tenants/
    tenant-demo.yaml     ← existing
    tenant-beta.yaml     ← new
    tenant-gamma.yaml    ← new
```

**Create an ArgoCD Application to manage all TCPs:**

```bash
kubectl apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kamaji-tenants
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/simonjday/kamaji-lab
    targetRevision: main
    path: manifests/tenants
  destination:
    server: https://kubernetes.default.svc
    namespace: tenant-demo
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

kubectl get applications -n argocd
```

**Demo flow:**

```bash
# 1. Edit manifests/tenants/tenant-demo.yaml in Git — change replica count to 2
# 2. git commit && git push
# 3. ArgoCD detects drift and syncs within 3 minutes
# 4. Watch TCP update
kubectl get tcp -A -w
```

---

## 7. GitOps — ArgoCD on Tenant Cluster

**Goal:** Deploy workloads to Capsule tenant namespaces from Git using ArgoCD running inside the tenant cluster.

**Install ArgoCD on the tenant cluster:**

```bash
use-tenant tenant-demo

kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl rollout status deployment/argocd-server -n argocd --timeout=180s

kubectl port-forward svc/argocd-server -n argocd 9090:443 &
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)
echo "ArgoCD password: ${ARGOCD_PASSWORD}"
open https://localhost:9090
```

**Create a sample app manifest in Git:**

```yaml
# manifests/apps/nginx-frontend.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: team-alpha-frontend
spec:
  replicas: 2
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
        image: nginx:alpine
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
```

**Create ArgoCD Application:**

```bash
kubectl apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: team-alpha-frontend-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/simonjday/kamaji-lab
    targetRevision: main
    path: manifests/apps
  destination:
    server: https://kubernetes.default.svc
    namespace: team-alpha-frontend
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
```

---

## 8. GitOps — ApplicationSet per Capsule Tenant

**Goal:** Use ArgoCD ApplicationSet to automatically generate one Application per Capsule tenant namespace — as namespaces are added, ArgoCD apps are created automatically.

**Install ApplicationSet controller** (included in ArgoCD 2.3+, already available).

**Create the ApplicationSet:**

```bash
use-tenant tenant-demo

kubectl apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: capsule-tenant-apps
  namespace: argocd
spec:
  generators:
  - clusters:
      selector:
        matchLabels: {}
    values:
      namespaces: team-alpha-frontend,team-alpha-backend,team-alpha-data
  - list:
      elements:
      - namespace: team-alpha-frontend
      - namespace: team-alpha-backend
      - namespace: team-alpha-data
  template:
    metadata:
      name: '{{namespace}}-app'
    spec:
      project: default
      source:
        repoURL: https://github.com/simonjday/kamaji-lab
        targetRevision: main
        path: 'manifests/apps/{{namespace}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{namespace}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=false
EOF

kubectl get applications -n argocd
# team-alpha-frontend-app
# team-alpha-backend-app
# team-alpha-data-app
```

**Demo:** Add a new namespace → ArgoCD automatically creates an Application for it.

---

## 9. Observability — Prometheus + Grafana on Tenant Cluster

**Goal:** Scrape worker node metrics from within the tenant cluster.

**Install kube-prometheus-stack:**

```bash
use-tenant tenant-demo

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set grafana.adminPassword=admin123 \
  --set alertmanager.enabled=false \
  --wait

kubectl get pods -n monitoring
```

**Access Grafana:**

```bash
kubectl port-forward svc/monitoring-grafana -n monitoring 3000:80 &
open http://localhost:3000
# Login: admin / admin123
```

**Useful dashboards to import:**

| Dashboard ID | Description |
|---|---|
| 315 | Kubernetes cluster monitoring |
| 6417 | Kubernetes pod/namespace overview |
| 1860 | Node Exporter full |

**Import via Grafana UI:** Dashboards → Import → Enter ID → Load.

**Demo — show worker node metrics:**

```bash
# Generate some load on worker-01
kubectl run stress --image=progrium/stress \
  --namespace team-alpha-frontend \
  -- stress --cpu 1 --timeout 60

# Watch CPU spike in Grafana node dashboard
```

**Verify scraping:**

```bash
kubectl get servicemonitors -A
kubectl get prometheusrules -A
```

---

## 10. Observability — Kamaji etcd Monitoring

**Goal:** Monitor the shared kamaji-etcd StatefulSet from the management cluster.

**Install Prometheus on the management cluster:**

```bash
use-mgmt

helm install mgmt-monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set grafana.adminPassword=admin123 \
  --set alertmanager.enabled=false \
  --wait
```

**Create ServiceMonitor for kamaji-etcd:**

```bash
kubectl apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kamaji-etcd
  namespace: monitoring
  labels:
    release: mgmt-monitoring
spec:
  namespaceSelector:
    matchNames:
      - kamaji-system
  selector:
    matchLabels:
      app.kubernetes.io/name: etcd
  endpoints:
    - port: client
      scheme: https
      tlsConfig:
        caFile: /etc/prometheus/secrets/kamaji-etcd-certs/ca.crt
        certFile: /etc/prometheus/secrets/kamaji-etcd-certs/tls.crt
        keyFile: /etc/prometheus/secrets/kamaji-etcd-certs/tls.key
        insecureSkipVerify: true
      interval: 15s
EOF
```

**Access Grafana:**

```bash
kubectl port-forward svc/mgmt-monitoring-grafana -n monitoring 3001:80 &
open http://localhost:3001
# Login: admin / admin123
```

**Import etcd dashboard:**

| Dashboard ID | Description |
|---|---|
| 3070 | etcd cluster overview |

**Key metrics to watch:**

```promql
# etcd leader changes (should be 0 in stable cluster)
etcd_server_leader_changes_seen_total

# etcd disk fsync latency
histogram_quantile(0.99, etcd_disk_wal_fsync_duration_seconds_bucket)

# Kamaji TCP reconciliation rate
controller_runtime_reconcile_total{controller="tenantcontrolplane"}
```

---

## Teardown

After completing demos, clean up with:

```bash
./scripts/teardown.sh
# Removes kind cluster, all Docker worker containers, and kubeconfigs
```

To remove only specific components:

```bash
./scripts/teardown.sh worker kamaji-worker-beta-01
./scripts/teardown.sh cluster
```
