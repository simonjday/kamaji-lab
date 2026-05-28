#!/usr/bin/env bash
# setup-worker-node.sh — Join a Multipass VM worker to a Kamaji TenantControlPlane
#
# Usage: ./scripts/setup-worker-node.sh <tcp-name> <tcp-namespace> [worker-name]
#
# Tested on: macOS M3, Lima usernet management cluster, Kamaji, K8s v1.32
#
# Why Multipass not Lima:
#   Lima usernet (SLIRP) isolates VMs — worker-01 can't reach kamaji-k3s MetalLB IPs.
#   Multipass uses bridged networking — worker reaches TCP via Mac host port-forward.
#
# Network flow:
#   worker-01 (192.168.252.x) → Mac gateway (192.168.252.1) port-forward → TCP (192.168.5.200)
#
# Why not kubeadm join:
#   Kamaji TCPs don't create the cluster-info ConfigMap kubeadm token discovery requires.
#   We configure kubelet directly with a kubeconfig instead.
#
# Port-forward requirements (all must stay running while cluster is in use):
#   :7443        → TCP:6443  (127.0.0.1 — for kubectl)
#   :16443       → TCP:6443  (0.0.0.0   — for kubelet API connection)
#   :8132        → TCP:8132  (192.168.252.1 — for konnectivity agent)
#   :6443        → TCP:6443  (192.168.252.1 — for pod-to-API ClusterIP routing)

set -euo pipefail

TCP_NAME="${1:?"Usage: $0 <tcp-name> <tcp-namespace> [worker-name]"}"
TCP_NS="${2:?"Usage: $0 <tcp-name> <tcp-namespace> [worker-name]"}"
WORKER_NAME="${3:-worker-01}"

MGMT_KUBECONFIG="${HOME}/.kube/k3s-kamaji.kubeconfig"
TENANT_KUBECONFIG="${HOME}/.kube/${TCP_NAME}-local.kubeconfig"
KUBECTL_PORT=7443
WORKER_PORT=16443

# ── Preflight ──────────────────────────────────────────────────────────────────
for f in "${MGMT_KUBECONFIG}" "${TENANT_KUBECONFIG}"; do
  if [ ! -f "${f}" ]; then
    echo "ERROR: Required kubeconfig not found: ${f}"
    echo "       Run: ./scripts/get-tenant-kubeconfig.sh ${TCP_NAME} ${TCP_NS}"
    exit 1
  fi
done

if ! command -v multipass &>/dev/null; then
  echo "ERROR: multipass not found.  brew install multipass"
  exit 1
fi

K8S_VERSION=$(KUBECONFIG=${MGMT_KUBECONFIG} kubectl get tcp "${TCP_NAME}" -n "${TCP_NS}" \
  -o jsonpath='{.spec.kubernetes.version}')
K8S_MINOR=$(echo "${K8S_VERSION#v}" | cut -d. -f1-2)

echo "==> TCP:    ${TCP_NAME} (ns: ${TCP_NS})"
echo "==> Worker: ${WORKER_NAME}"
echo "==> K8s:    ${K8S_VERSION}"

# ── Step 1: Create Multipass VM ────────────────────────────────────────────────
if multipass info "${WORKER_NAME}" &>/dev/null 2>&1; then
  echo "==> Multipass VM '${WORKER_NAME}' already exists"
else
  echo ""
  echo "==> Step 1/6: Creating Multipass VM: ${WORKER_NAME}"
  multipass launch --name "${WORKER_NAME}" --cpus 2 --memory 4G --disk 20G jammy
fi

WORKER_IP=$(multipass info "${WORKER_NAME}" | grep IPv4 | awk '{print $2}')
GATEWAY_IP=$(echo "${WORKER_IP}" | awk -F. '{print $1"."$2"."$3".1"}')
echo "==> Worker IP:  ${WORKER_IP}"
echo "==> Gateway IP: ${GATEWAY_IP}"

# ── Step 2: Start all required port-forwards ──────────────────────────────────
echo ""
echo "==> Step 2/6: Starting port-forwards"
pkill -f "kubectl port-forward svc/${TCP_NAME}" 2>/dev/null || true
sleep 2

KUBECONFIG=${MGMT_KUBECONFIG}
export KUBECONFIG

# kubectl access (localhost)
while true; do kubectl port-forward svc/${TCP_NAME} -n ${TCP_NS} \
  ${KUBECTL_PORT}:6443 --address 127.0.0.1 2>/dev/null; sleep 2; done &

# kubelet access (all interfaces)
while true; do kubectl port-forward svc/${TCP_NAME} -n ${TCP_NS} \
  ${WORKER_PORT}:6443 --address 0.0.0.0 2>/dev/null; sleep 2; done &

# ClusterIP routing — pods reach 10.96.0.1 via kube-proxy → gateway:6443
while true; do kubectl port-forward svc/${TCP_NAME} -n ${TCP_NS} \
  6443:6443 --address ${GATEWAY_IP} 2>/dev/null; sleep 2; done &

# Konnectivity tunnel — agent connects to gateway:8132
while true; do kubectl port-forward svc/${TCP_NAME} -n ${TCP_NS} \
  8132:8132 --address ${GATEWAY_IP} 2>/dev/null; sleep 2; done &

sleep 4
echo "==> Port-forwards running"

# Test worker → TCP connectivity
if ! multipass exec "${WORKER_NAME}" -- \
    curl -sk --connect-timeout 5 "https://${GATEWAY_IP}:${WORKER_PORT}/version" &>/dev/null; then
  echo "ERROR: Worker cannot reach TCP via ${GATEWAY_IP}:${WORKER_PORT}"
  exit 1
fi
echo "==> Worker → TCP connectivity confirmed"

# ── Step 3: Patch TCP certSANs and advertiseAddress ───────────────────────────
echo ""
echo "==> Step 3/6: Patching TCP certSANs and advertiseAddress"

export KUBECONFIG=${MGMT_KUBECONFIG}
kubectl patch tcp "${TCP_NAME}" -n "${TCP_NS}" --type=merge -p "{
  \"spec\": {
    \"networkProfile\": {
      \"advertiseAddress\": \"${GATEWAY_IP}\",
      \"certSANs\": [\"${GATEWAY_IP}\"]
    }
  }
}"

echo "==> Waiting for TCP to reissue certs (~30s)"
sleep 10
TIMEOUT=90
ELAPSED=0
until kubectl get tcp "${TCP_NAME}" -n "${TCP_NS}" \
    -o jsonpath='{.status.kubernetesResources.version.status}' 2>/dev/null | grep -q Ready; do
  if [ "${ELAPSED}" -ge "${TIMEOUT}" ]; then
    echo "ERROR: TCP did not return to Ready"
    exit 1
  fi
  echo "  ... waiting (${ELAPSED}s)"
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done
echo "==> TCP Ready"

# ── Step 4: Install containerd + kubelet on worker ────────────────────────────
echo ""
echo "==> Step 4/6: Installing containerd + kubelet ${K8S_VERSION} on ${WORKER_NAME}"

multipass exec "${WORKER_NAME}" -- bash -c "
  set -euo pipefail
  sudo apt-get update -qq
  sudo apt-get install -y -qq apt-transport-https ca-certificates curl gpg containerd iptables

  # Use iptables-legacy — Ubuntu 22.04 nftables is incompatible with kube-proxy
  sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
  sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy

  # Configure containerd with systemd cgroup driver
  sudo mkdir -p /etc/containerd
  containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
  sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  sudo systemctl restart containerd && sudo systemctl enable containerd

  # Fix crictl to avoid endpoint detection hangs
  sudo tee /etc/crictl.yaml > /dev/null <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

  # Kubernetes apt repo
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key | \
    sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg 2>/dev/null
  echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /' | \
    sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
  sudo apt-get update -qq && sudo apt-get install -y kubelet
  sudo apt-mark hold kubelet

  # Kernel requirements
  sudo swapoff -a
  sudo sed -i '/ swap / s/^/#/' /etc/fstab
  sudo modprobe overlay br_netfilter
  # Persist modules across reboots
  echo -e 'overlay\nbr_netfilter' | sudo tee /etc/modules-load.d/k8s.conf > /dev/null
  printf 'net.bridge.bridge-nf-call-iptables=1\nnet.ipv4.ip_forward=1\n' | \
    sudo tee /etc/sysctl.d/k8s.conf > /dev/null
  sudo sysctl --system -q

  # Fix DNS loop: disable systemd-resolved stub so CoreDNS doesn't loop via /etc/resolv.conf
  echo 'DNSStubListener=no' | sudo tee -a /etc/systemd/resolved.conf > /dev/null
  sudo systemctl restart systemd-resolved
  sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

  echo '==> Worker OS configuration complete'
"

# ── Step 5: Configure kubelet ─────────────────────────────────────────────────
echo ""
echo "==> Step 5/6: Configuring kubelet"

# Copy CA cert
KUBECONFIG=${MGMT_KUBECONFIG} kubectl get secret "${TCP_NAME}-ca" -n "${TCP_NS}" \
  -o jsonpath='{.data.ca\.crt}' | base64 -d | \
  multipass exec "${WORKER_NAME}" -- bash -c "
    sudo mkdir -p /etc/kubernetes/pki
    sudo tee /etc/kubernetes/pki/ca.crt > /dev/null
  "

CLIENT_CERT=$(grep client-certificate-data "${TENANT_KUBECONFIG}" | awk '{print $2}')
CLIENT_KEY=$(grep client-key-data "${TENANT_KUBECONFIG}" | awk '{print $2}')

multipass exec "${WORKER_NAME}" -- bash -c "
  cat <<EOF | sudo tee /etc/kubernetes/kubelet.conf > /dev/null
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority: /etc/kubernetes/pki/ca.crt
    server: https://${GATEWAY_IP}:${WORKER_PORT}
  name: ${TCP_NAME}
contexts:
- context:
    cluster: ${TCP_NAME}
    user: kubernetes-admin
  name: kubernetes-admin@${TCP_NAME}
current-context: kubernetes-admin@${TCP_NAME}
users:
- name: kubernetes-admin
  user:
    client-certificate-data: ${CLIENT_CERT}
    client-key-data: ${CLIENT_KEY}
EOF

  sudo mkdir -p /var/lib/kubelet
  cat <<'KUBECFG' | sudo tee /var/lib/kubelet/config.yaml > /dev/null
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
KUBECFG

  echo 'KUBELET_KUBEADM_ARGS=\"--container-runtime-endpoint=unix:///var/run/containerd/containerd.sock --hostname-override=${WORKER_NAME}\"' | \
    sudo tee /var/lib/kubelet/kubeadm-flags.env > /dev/null
  sudo systemctl daemon-reload && sudo systemctl restart kubelet
"

# ── Step 6: Fix RBAC, install Flannel, verify ─────────────────────────────────
echo ""
echo "==> Step 6/6: RBAC, Flannel CNI, verification"

export KUBECONFIG=${TENANT_KUBECONFIG}

# Grant API server permission to proxy to kubelet
kubectl apply -f - <<'EOF'
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

# Install Flannel
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

echo "==> Waiting for worker node to become Ready"
TIMEOUT=120
ELAPSED=0
until kubectl get nodes --no-headers 2>/dev/null | grep "${WORKER_NAME}" | grep -q " Ready"; do
  if [ "${ELAPSED}" -ge "${TIMEOUT}" ]; then
    echo "WARNING: Timed out waiting for node Ready"
    break
  fi
  echo "  ... waiting (${ELAPSED}s)"
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

echo ""
echo "======================================================"
echo " Worker node joined: ${WORKER_NAME}"
echo "======================================================"
kubectl get nodes -o wide
echo ""
echo "==> Waiting for all pods to be Running (~3 min for image pulls)"
kubectl get pods -A
echo ""
echo " Port-forwards required while cluster is in use:"
echo "   :7443  → kubectl access (localhost)"
echo "   :16443 → kubelet (0.0.0.0)"
echo "   :6443  → ClusterIP routing (${GATEWAY_IP})"
echo "   :8132  → konnectivity (${GATEWAY_IP})"
echo ""
echo " use-tenant tenant-demo starts all four automatically."
echo "======================================================"
