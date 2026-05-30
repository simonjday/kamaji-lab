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

> **Version constraint in this lab:** Kamaji v1.0.0 with kind v1.34 management cluster supports TCP versions up to `v1.30.2` only. Attempting to set `v1.30.9` or higher is rejected by the admission webhook with:
> ```
> unable to upgrade to a version greater than the supported one, actually 1.30.2
> ```
> In a production environment with a newer Kamaji and management cluster you would patch to any supported version. The upgrade mechanism shown below is accurate — only the version numbers differ.

**What the upgrade looks like (production):**

```bash
# In a production Kamaji environment supporting v1.32.x:
kubectl patch tcp tenant-demo -n tenant-demo --type=merge \
  -p '{"spec":{"kubernetes":{"version":"v1.32.5"}}}'

# Watch Kamaji roll the control plane
kubectl get tcp -n tenant-demo -w
# STATUS goes: Ready → Upgrading → Ready
# Takes ~30-60 seconds

kubectl get pods -n tenant-demo -w
# Old pod terminated, new pod starts with v1.32.5 images
```

**What you CAN demo in this lab — replica scaling (shows same reconcile pattern):**

```bash
# Scale the TCP control plane from 1 to 2 replicas
kubectl patch tcp tenant-demo -n tenant-demo --type=merge \
  -p '{"spec":{"controlPlane":{"deployment":{"replicas":2}}}}'

# Watch Kamaji add the second replica
kubectl get pods -n tenant-demo -w
# tenant-demo-xxx-1   4/4   Running
# tenant-demo-xxx-2   4/4   Running  ← new replica

kubectl get tcp -n tenant-demo
# Shows 2/2 pods

# Scale back down
kubectl patch tcp tenant-demo -n tenant-demo --type=merge \
  -p '{"spec":{"controlPlane":{"deployment":{"replicas":1}}}}'
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

**Reset after demo:**

```bash
# Scale back to 1 replica
use-mgmt
kubectl patch tcp tenant-demo -n tenant-demo --type=merge   -p '{"spec":{"controlPlane":{"deployment":{"replicas":1}}}}'
kubectl get pods -n tenant-demo -w
```

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
sleep 3
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

**Reset after demo:**

```bash
use-mgmt

# Remove worker
./scripts/teardown.sh worker kamaji-worker-beta-01

# Remove TCP and namespace
kubectl delete tcp tenant-beta -n tenant-beta
kubectl delete ns tenant-beta

# Remove kubeconfigs
rm -f ~/.kube/tenant-beta.kubeconfig ~/.kube/tenant-beta-local.kubeconfig

# Kill port-forward
lsof -ti:7444 | xargs kill -9 2>/dev/null || true
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

> **Important:** Set `destination.namespace` to `""` (empty) so ArgoCD manages TCPs across all namespaces, not just one. If set to a specific namespace, ArgoCD will only track resources in that namespace and `prune: true` won't remove TCPs in other namespaces.

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
    namespace: ""
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

kubectl get applications -n argocd
```

> **Note:** Each TCP manifest needs a corresponding Namespace manifest in Git for `CreateNamespace=true` to work correctly. Create both files together:
> ```
> manifests/tenants/tenant-gamma-ns.yaml   # Namespace
> manifests/tenants/tenant-gamma.yaml      # TenantControlPlane
> ```

**Demo flow:**

```bash
# 1. Add namespace + TCP manifests to Git
cat > manifests/tenants/tenant-gamma-ns.yaml <<'NSEOF'
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-gamma
NSEOF

cat > manifests/tenants/tenant-gamma.yaml <<'TCPEOF'
apiVersion: kamaji.clastix.io/v1alpha1
kind: TenantControlPlane
metadata:
  name: tenant-gamma
  namespace: tenant-gamma
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
TCPEOF

git add manifests/tenants/
git commit -m "Demo: add tenant-gamma via GitOps"
git push

# 2. Watch ArgoCD provision the TCP (polls every 3 min, or force sync below)
kubectl get tcp -A -w

# Force immediate sync if needed:
kubectl -n argocd patch application kamaji-tenants   --type merge   -p '{"operation":{"sync":{"revision":"HEAD"}}}'

# 3. Remove from Git — ArgoCD prunes the TCP
git rm manifests/tenants/tenant-gamma.yaml manifests/tenants/tenant-gamma-ns.yaml
git commit -m "Demo: remove tenant-gamma via GitOps"
git push

kubectl get tcp -A -w
# tenant-gamma disappears
```

**Reset after demo:**

```bash
use-mgmt

# Remove the ArgoCD application
kubectl delete application kamaji-tenants -n argocd

# Uninstall ArgoCD
kubectl delete -n argocd   -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl delete namespace argocd

# Kill port-forward
lsof -ti:8888 | xargs kill -9 2>/dev/null || true
```

---

## 7. GitOps — ArgoCD on Tenant Cluster

**Goal:** Deploy workloads to Capsule tenant namespaces from Git using ArgoCD running inside the tenant cluster.

> **Capsule namespace restriction:** Capsule blocks creation of namespaces that don't match a tenant prefix. `argocd` is a system namespace and must be exempt. The Capsule `protectedNamespaceRegex` field covers namespaces that Capsule should ignore entirely.

**Install ArgoCD on the tenant cluster:**

```bash
use-tenant tenant-demo

# Exempt system namespaces from Capsule tenant enforcement
# Without this, Capsule blocks argocd namespace creation
kubectl patch capsuleconfiguration default --type=merge -p '{
  "spec": {
    "protectedNamespaceRegex": "^(argocd|monitoring|cert-manager|capsule-system|kube-.*)$"
  }
}'

kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# The applicationsets CRD annotation warning is harmless — ignore it
kubectl rollout status deployment/argocd-server -n argocd --timeout=180s

ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)
echo "ArgoCD password: ${ARGOCD_PASSWORD}"

kubectl port-forward svc/argocd-server -n argocd 9090:443 &
sleep 2
open https://localhost:9090
# Login: admin / <password above>
```

> **Port-forward note:** The ArgoCD UI port-forward must be started from the tenant cluster context. If you switch contexts with `use-mgmt`, the port-forward will drop. Re-run from `use-tenant tenant-demo`.

**Create app manifests in Git:**

```bash
mkdir -p manifests/apps/team-alpha-frontend

cat > manifests/apps/team-alpha-frontend/nginx.yaml <<'EOF'
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
---
apiVersion: v1
kind: Service
metadata:
  name: nginx
  namespace: team-alpha-frontend
spec:
  selector:
    app: nginx
  ports:
  - port: 80
    targetPort: 80
EOF

git add manifests/apps/
git commit -m "Demo: add nginx app for team-alpha-frontend"
git push
```

**Create ArgoCD Application on the tenant cluster:**

```bash
# Ensure you are on the tenant cluster
use-tenant tenant-demo

kubectl apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: team-alpha-frontend
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/simonjday/kamaji-lab
    targetRevision: main
    path: manifests/apps/team-alpha-frontend
  destination:
    server: https://kubernetes.default.svc
    namespace: team-alpha-frontend
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

kubectl get applications -n argocd -w
# Synced → Healthy
```

**Verify deployment:**

```bash
kubectl get pods -n team-alpha-frontend
# NAME                     READY   STATUS    RESTARTS   AGE
# nginx-xxx-1              1/1     Running   0          30s
# nginx-xxx-2              1/1     Running   0          30s

kubectl get svc -n team-alpha-frontend
# NAME    TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
# nginx   ClusterIP   10.96.75.253   <none>        80/TCP    30s
```

**Demo — GitOps loop (scale via Git):**

```bash
# Change replicas in Git
sed -i '' 's/replicas: 2/replicas: 3/' manifests/apps/team-alpha-frontend/nginx.yaml
git add manifests/apps/team-alpha-frontend/nginx.yaml
git commit -m "Demo: scale nginx to 3 replicas"
git push

# Force sync or wait up to 3 minutes
kubectl -n argocd patch application team-alpha-frontend \
  --type merge \
  -p '{"operation":{"sync":{"revision":"HEAD"}}}'

kubectl get pods -n team-alpha-frontend -w
# Third pod appears automatically
```

**Reset after demo:**

```bash
use-tenant tenant-demo

# Remove ArgoCD application and workloads
kubectl delete application team-alpha-frontend -n argocd
kubectl delete deploy nginx -n team-alpha-frontend 2>/dev/null || true
kubectl delete svc nginx -n team-alpha-frontend 2>/dev/null || true

# Uninstall ArgoCD from tenant cluster
kubectl delete -n argocd   -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl delete namespace argocd

# Kill port-forward
lsof -ti:9090 | xargs kill -9 2>/dev/null || true

# Remove app manifests from git
git rm -r manifests/apps/team-alpha-frontend/nginx.yaml 2>/dev/null || true
git commit -m "Demo cleanup: remove nginx app" 2>/dev/null || true
git push 2>/dev/null || true
```

---

## 8. GitOps — ApplicationSet per Capsule Tenant

**Goal:** Use ArgoCD ApplicationSet to automatically generate one Application per Capsule tenant namespace — as namespaces are added, ArgoCD apps are created automatically.

**Install ApplicationSet controller** (included in ArgoCD 2.3+, already available).

> **ApplicationSet CRD note:** The `applicationsets.argoproj.io` CRD may fail to install via standard `kubectl apply` due to an annotation size limit. If you see `metadata.annotations: Too long`, install with server-side apply:
> ```bash
> kubectl apply -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/crds/applicationset-crd.yaml >   --server-side --force-conflicts
> ```

**Create app manifests in Git for each namespace:**

```bash
mkdir -p manifests/apps/team-alpha-backend
mkdir -p manifests/apps/team-alpha-data

cat > manifests/apps/team-alpha-backend/nginx.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: team-alpha-backend
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
        image: nginx:alpine
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
EOF

cp manifests/apps/team-alpha-backend/nginx.yaml manifests/apps/team-alpha-data/nginx.yaml
sed -i '' 's/namespace: team-alpha-backend/namespace: team-alpha-data/'   manifests/apps/team-alpha-data/nginx.yaml

git add manifests/apps/
git commit -m "Demo: add apps for all team-alpha namespaces"
git push
```

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
  - list:
      elements:
      - namespace: team-alpha-frontend
      - namespace: team-alpha-backend
      - namespace: team-alpha-data
  template:
    metadata:
      name: '{{namespace}}'
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
EOF

kubectl get applicationsets -n argocd
kubectl get applications -n argocd
# NAME                  SYNC STATUS   HEALTH STATUS
# team-alpha-backend    Synced        Healthy
# team-alpha-data       Synced        Healthy
# team-alpha-frontend   Synced        Healthy
```

> **Force sync if status stays Unknown:**
> ```bash
> kubectl -n argocd patch application team-alpha-backend >   --type merge -p '{"operation":{"sync":{"revision":"HEAD"}}}'
> kubectl -n argocd patch application team-alpha-data >   --type merge -p '{"operation":{"sync":{"revision":"HEAD"}}}'
> ```

**Verify pods in all three namespaces:**

```bash
kubectl get pods -n team-alpha-frontend
kubectl get pods -n team-alpha-backend
kubectl get pods -n team-alpha-data
# nginx running in each namespace
```

**Demo — add a new namespace, ApplicationSet auto-creates Application:**

```bash
# Alice creates a new namespace
kubectl --as=alice --as-group=projectcapsule.dev create namespace team-alpha-staging

# Add app manifest to Git
mkdir -p manifests/apps/team-alpha-staging
cp manifests/apps/team-alpha-backend/nginx.yaml manifests/apps/team-alpha-staging/nginx.yaml
sed -i '' 's/namespace: team-alpha-backend/namespace: team-alpha-staging/'   manifests/apps/team-alpha-staging/nginx.yaml

# Add to ApplicationSet generator list
kubectl patch applicationset capsule-tenant-apps -n argocd --type=json -p '[
  {"op": "add", "path": "/spec/generators/0/list/elements/-",
   "value": {"namespace": "team-alpha-staging"}}
]'

git add manifests/apps/team-alpha-staging/
git commit -m "Demo: add team-alpha-staging app"
git push

kubectl get applications -n argocd
# team-alpha-staging Application appears automatically
```

**Reset after demo:**

```bash
use-tenant tenant-demo

# Delete ApplicationSet and all generated Applications
kubectl delete applicationset capsule-tenant-apps -n argocd
kubectl delete application team-alpha-frontend team-alpha-backend   team-alpha-data -n argocd 2>/dev/null || true

# Clean up workloads
kubectl delete deploy nginx -n team-alpha-frontend 2>/dev/null || true
kubectl delete deploy nginx -n team-alpha-backend 2>/dev/null || true
kubectl delete deploy nginx -n team-alpha-data 2>/dev/null || true
kubectl delete svc nginx -n team-alpha-frontend 2>/dev/null || true

# Remove app manifests from git
git rm -r manifests/apps/ 2>/dev/null || true
git commit -m "Demo cleanup: remove app manifests" 2>/dev/null || true
git push 2>/dev/null || true
```

---

## 9. Observability — Prometheus + Grafana on Tenant Cluster

**Goal:** Scrape worker node metrics from within the tenant cluster.

> **Capsule namespace note:** The `monitoring` namespace must be exempt from Capsule enforcement. Ensure `protectedNamespaceRegex` includes `monitoring` (done in demo 7 setup).

**Install kube-prometheus-stack:**

```bash
use-tenant tenant-demo

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community

helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set grafana.adminPassword=admin123 \
  --set alertmanager.enabled=false \
  --wait --timeout=300s

kubectl get pods -n monitoring
```

**Access Grafana:**

```bash
kubectl port-forward svc/monitoring-grafana -n monitoring 3000:80 &
sleep 2
open http://localhost:3000
# Login: admin / admin123
```

**Access Prometheus targets:**

```bash
kubectl port-forward svc/monitoring-kube-prometheus-prometheus   -n monitoring 9091:9090 &
sleep 2
open http://localhost:9091/targets
# CoreDNS and kube-state-metrics targets show as UP
```

**Useful dashboards to import:**

| Dashboard ID | Description | Notes |
|---|---|---|
| 6417 | Kubernetes Cluster (Prometheus) | Works — shows pods, deployments, node count |
| 315 | Kubernetes cluster monitoring | Partial — node CPU/memory N/A (Docker container limitation) |
| 1860 | Node Exporter full | N/A in kind Docker worker setup |

**Import via Grafana UI:** Dashboards → Import → Enter ID → Load → Select Prometheus datasource.

> **Lab limitation:** Node-level metrics (CPU, memory, disk) show N/A because the node-exporter cannot reach the Docker container host network. Workload metrics (pods, deployments, replicas) work correctly via kube-state-metrics.

**Demo — show workload metrics in Grafana (dashboard 6417):**

```bash
# Generate pod activity — scale nginx up and down
export KUBECONFIG=~/.kube/tenant-demo-local.kubeconfig
kubectl scale deploy nginx -n team-alpha-frontend --replicas=5
sleep 30
kubectl scale deploy nginx -n team-alpha-frontend --replicas=2

# Watch deployment replica changes appear in Grafana
# Dashboard 6417 → Deployments section → Deployment Replicas
```

**Verify scraping:**

```bash
kubectl get servicemonitors -n monitoring
# Shows: coredns, kube-state-metrics, prometheus, node-exporter
```

**Reset after demo:**

```bash
use-tenant tenant-demo

helm uninstall monitoring -n monitoring
kubectl delete namespace monitoring

# Kill port-forwards
lsof -ti:3000 | xargs kill -9 2>/dev/null || true
lsof -ti:9091 | xargs kill -9 2>/dev/null || true
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

## Worker Restart Recovery

After Docker Desktop or macOS restarts, worker containers may lose runtime state (kube-proxy kubeconfig, conntrack config). Use the `recover-worker` shell helper:

```bash
# Recover tenant-demo worker
recover-worker tenant-demo

# Recover tenant-beta worker  
recover-worker tenant-beta tenant-beta kamaji-worker-beta-01
```

This automatically:
- Recreates the kube-proxy kubeconfig
- Fixes the conntrack configmap
- Deletes stuck pods to force a clean restart

**Why this happens:** The `/var/lib/kube-proxy` directory was not persisted as a Docker volume in earlier worker setups. Workers created with the updated `setup-worker-kind.sh` (v2+) include `-v /var/lib/kube-proxy` and will survive restarts without needing recovery.

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
