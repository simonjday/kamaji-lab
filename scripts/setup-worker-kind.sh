#!/usr/bin/env bash
# setup-worker-kind.sh — Join a Docker container worker to a Kamaji TenantControlPlane
#
# Tested on: macOS M3, kind management cluster, Kamaji, K8s v1.30.2
#
# Architecture:
#   Docker container (kindest/node:v1.30.2) runs in the 'kind' Docker network.
#   The kind network provides direct access to MetalLB IPs (172.18.255.x).
#   No port-forwarding or VM networking required for the worker.
#
# Why not kubeadm join:
#   Kamaji TCPs don't create the cluster-info ConfigMap kubeadm token discovery needs.
#   We configure kubelet directly with a bootstrap kubeconfig instead.
#
# Usage: ./scripts/setup-worker-kind.sh <tcp-name> <tcp-namespace> [worker-name]

set -euo pipefail

TCP_NAME="${1:?"Usage: $0 <tcp-name> <tcp-namespace> [worker-name]"}"
TCP_NS="${2:?"Usage: $0 <tcp-name> <tcp-namespace> [worker-name]"}"
WORKER_NAME="${3:-kamaji-worker-01}"

MGMT_KUBECONFIG="${HOME}/.kube/config"
TENANT_KUBECONFIG="${HOME}/.kube/${TCP_NAME}-local.kubeconfig"

# ── Preflight ──────────────────────────────────────────────────────────────────
if ! kubectl --kubeconfig "${MGMT_KUBECONFIG}" get tcp "${TCP_NAME}" -n "${TCP_NS}" \
    &>/dev/null 2>&1; then
  echo "ERROR: TCP '${TCP_NAME}' not found in namespace '${TCP_NS}'"
  exit 1
fi

# Get TCP details
TCP_ENDPOINT=$(kubectl --kubeconfig "${MGMT_KUBECONFIG}" get tcp "${TCP_NAME}" \
  -n "${TCP_NS}" -o jsonpath='{.status.controlPlaneEndpoint}')
K8S_VERSION=$(kubectl --kubeconfig "${MGMT_KUBECONFIG}" get tcp "${TCP_NAME}" \
  -n "${TCP_NS}" -o jsonpath='{.spec.kubernetes.version}')

echo "==> TCP:      ${TCP_NAME} (ns: ${TCP_NS})"
echo "==> Endpoint: ${TCP_ENDPOINT}"
echo "==> K8s:      ${K8S_VERSION}"
echo "==> Worker:   ${WORKER_NAME}"

# ── Ensure tenant kubeconfig and port-forward ──────────────────────────────────
if [ ! -f "${TENANT_KUBECONFIG}" ]; then
  echo "==> Extracting tenant kubeconfig"

  RAW_KUBECONFIG="${HOME}/.kube/${TCP_NAME}.kubeconfig"
  kubectl --kubeconfig "${MGMT_KUBECONFIG}" get secret \
    "${TCP_NAME}-admin-kubeconfig" -n "${TCP_NS}" \
    -o jsonpath='{.data.admin\.conf}' | base64 -d > "${RAW_KUBECONFIG}"

  sed "s|https://${TCP_ENDPOINT}|https://127.0.0.1:7443|g" \
    "${RAW_KUBECONFIG}" > "${TENANT_KUBECONFIG}"
  chmod 600 "${RAW_KUBECONFIG}" "${TENANT_KUBECONFIG}"
fi

# Ensure port-forward is running
if ! lsof -i:7443 &>/dev/null 2>&1; then
  echo "==> Starting port-forward :7443 → ${TCP_NAME}:6443"
  kubectl --kubeconfig "${MGMT_KUBECONFIG}" port-forward \
    svc/${TCP_NAME} -n ${TCP_NS} 7443:6443 \
    --address 127.0.0.1 >/dev/null 2>&1 &
  sleep 3
fi

# ── Step 1: Create worker container ───────────────────────────────────────────
echo ""
echo "==> Step 1/6: Creating worker container: ${WORKER_NAME}"

if docker ps -a --format '{{.Names}}' | grep -q "^${WORKER_NAME}$"; then
  echo "==> Container '${WORKER_NAME}' already exists"
  docker start "${WORKER_NAME}" 2>/dev/null || true
else
  docker run -d \
    --name "${WORKER_NAME}" \
    --hostname "${WORKER_NAME#kamaji-}" \
    --network kind \
    --privileged \
    --tmpfs /tmp \
    --tmpfs /run \
    -v /var/lib/containerd \
    -v /var/lib/kubelet \
    -v /etc/kubernetes \
    "kindest/node:${K8S_VERSION}"

  sleep 5
fi

WORKER_IP=$(docker inspect "${WORKER_NAME}" \
  -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
echo "==> Worker IP: ${WORKER_IP}"

# ── Step 2: Install CNI plugins ───────────────────────────────────────────────
echo ""
echo "==> Step 2/6: Installing CNI plugins"

ARCH=$(docker exec "${WORKER_NAME}" uname -m)
case "${ARCH}" in
  aarch64|arm64) CNI_ARCH="arm64" ;;
  x86_64)        CNI_ARCH="amd64" ;;
  *) CNI_ARCH="amd64" ;;
esac

docker exec "${WORKER_NAME}" bash -c "
  curl -sL https://github.com/containernetworking/plugins/releases/download/v1.5.1/cni-plugins-linux-${CNI_ARCH}-v1.5.1.tgz | \
    tar -xz -C /opt/cni/bin 2>/dev/null
  ls /opt/cni/bin/bridge &>/dev/null && echo '==> CNI plugins installed' || echo 'ERROR: CNI install failed'
"

# ── Step 3: Generate bootstrap credentials ────────────────────────────────────
echo ""
echo "==> Step 3/6: Generating bootstrap credentials"

CA_DATA=$(kubectl --kubeconfig "${MGMT_KUBECONFIG}" get secret \
  "${TCP_NAME}-ca" -n "${TCP_NS}" -o jsonpath='{.data.ca\.crt}')

CA_HASH=$(echo "${CA_DATA}" | base64 -d | \
  openssl x509 -pubkey -noout | \
  openssl pkey -pubin -outform DER | \
  openssl dgst -sha256 | awk '{print $2}')

TOKEN_ID=$(openssl rand -hex 3)
TOKEN_SECRET=$(openssl rand -hex 8)

kubectl --kubeconfig "${TENANT_KUBECONFIG}" apply -f - <<EOF
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

echo "==> Bootstrap token: ${TOKEN_ID}.${TOKEN_SECRET}"

# ── Step 4: Configure kubelet ─────────────────────────────────────────────────
echo ""
echo "==> Step 4/6: Configuring kubelet"

HOSTNAME=$(docker exec "${WORKER_NAME}" hostname)

# Copy CA cert into worker container first
echo "${CA_DATA}" | base64 -d > /tmp/worker-ca.crt
docker exec "${WORKER_NAME}" mkdir -p /etc/kubernetes/pki
docker cp /tmp/worker-ca.crt "${WORKER_NAME}:/etc/kubernetes/pki/ca.crt"

# Write bootstrap-kubelet.conf
cat > /tmp/bootstrap-kubelet.conf << EOF
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: ${CA_DATA}
    server: https://${TCP_ENDPOINT}
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
  "${WORKER_NAME}:/etc/kubernetes/bootstrap-kubelet.conf"

# Create minimal kubelet config.yaml (required for kubelet to start)
docker exec "${WORKER_NAME}" bash -c "
  mkdir -p /var/lib/kubelet
  cat > /var/lib/kubelet/config.yaml <<'KUBECFG'
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
clusterDNS:
  - 10.96.0.10
clusterDomain: cluster.local
KUBECFG"

# Disable swap check and restart kubelet
docker exec "${WORKER_NAME}" bash -c "
  rm -f /etc/kubernetes/kubelet.conf
  echo 'KUBELET_EXTRA_ARGS=--fail-swap-on=false' > /etc/default/kubelet
  systemctl daemon-reload
  systemctl restart kubelet
"

echo "==> Waiting for kubelet to start"
TIMEOUT=30
ELAPSED=0
until docker exec "${WORKER_NAME}" \
    systemctl is-active kubelet &>/dev/null 2>&1; do
  if [ "${ELAPSED}" -ge "${TIMEOUT}" ]; then
    echo "ERROR: kubelet failed to start"
    docker exec "${WORKER_NAME}" journalctl -u kubelet -n 10 --no-pager
    exit 1
  fi
  sleep 2
  ELAPSED=$((ELAPSED + 2))
done
echo "==> kubelet running"

# ── Step 5: Fix kube-proxy ────────────────────────────────────────────────────
echo ""
echo "==> Step 5/6: Fixing kube-proxy"

# Wait for node to register
echo "==> Waiting for node to register"
TIMEOUT=60
ELAPSED=0
until kubectl --kubeconfig "${TENANT_KUBECONFIG}" get nodes \
    --no-headers 2>/dev/null | grep -q "${HOSTNAME}"; do
  if [ "${ELAPSED}" -ge "${TIMEOUT}" ]; then
    echo "ERROR: Node did not register within ${TIMEOUT}s"
    exit 1
  fi
  sleep 3
  ELAPSED=$((ELAPSED + 3))
done

# Fix conntrack configmap
kubectl --kubeconfig "${TENANT_KUBECONFIG}" get configmap \
  kube-proxy -n kube-system -o jsonpath='{.data.config\.conf}' | \
  sed 's/maxPerCore: null/maxPerCore: 0/' | \
  sed 's/min: null/min: 0/' > /tmp/kube-proxy-config.conf

kubectl --kubeconfig "${TENANT_KUBECONFIG}" create configmap kube-proxy \
  -n kube-system \
  --from-file=config.conf=/tmp/kube-proxy-config.conf \
  --dry-run=client -o yaml | \
  kubectl --kubeconfig "${TENANT_KUBECONFIG}" apply -f -

# Create kube-proxy kubeconfig
PROXY_TOKEN=$(kubectl --kubeconfig "${TENANT_KUBECONFIG}" \
  create token kube-proxy -n kube-system 2>/dev/null || echo "")

cat > /tmp/kube-proxy.conf << EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${CA_DATA}
    server: https://${TCP_ENDPOINT}
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
    token: ${PROXY_TOKEN}
EOF

docker exec "${WORKER_NAME}" mkdir -p /var/lib/kube-proxy
docker cp /tmp/kube-proxy.conf "${WORKER_NAME}:/var/lib/kube-proxy/kubeconfig.conf"

kubectl --kubeconfig "${TENANT_KUBECONFIG}" delete pod \
  -n kube-system -l k8s-app=kube-proxy 2>/dev/null || true

# ── Step 6: Install Flannel and verify ────────────────────────────────────────
echo ""
echo "==> Step 6/6: Installing Flannel CNI"

kubectl --kubeconfig "${TENANT_KUBECONFIG}" apply \
  -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# Delete stuck pods to restart with CNI
sleep 5
kubectl --kubeconfig "${TENANT_KUBECONFIG}" delete pod \
  -n kube-flannel --all 2>/dev/null || true
kubectl --kubeconfig "${TENANT_KUBECONFIG}" delete pod \
  -n kube-system -l k8s-app=coredns 2>/dev/null || true
kubectl --kubeconfig "${TENANT_KUBECONFIG}" delete pod \
  -n kube-system -l k8s-app=konnectivity-agent 2>/dev/null || true

echo "==> Waiting for node Ready"
TIMEOUT=120
ELAPSED=0
until kubectl --kubeconfig "${TENANT_KUBECONFIG}" get nodes \
    --no-headers 2>/dev/null | grep "${HOSTNAME}" | grep -q " Ready"; do
  if [ "${ELAPSED}" -ge "${TIMEOUT}" ]; then
    echo "WARNING: Node not Ready after ${TIMEOUT}s — check pods manually"
    break
  fi
  echo "  ... waiting (${ELAPSED}s)"
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

echo ""
echo "======================================================"
echo " Worker joined: ${WORKER_NAME}"
echo "======================================================"
kubectl --kubeconfig "${TENANT_KUBECONFIG}" get nodes -o wide
echo ""
kubectl --kubeconfig "${TENANT_KUBECONFIG}" get pods -A
echo "======================================================"
