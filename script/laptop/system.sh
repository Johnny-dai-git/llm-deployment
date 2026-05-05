#!/usr/bin/env bash
set -euo pipefail

# =========================
# Config
# =========================
NODE_NAME="system"
POD_CIDR="192.168.0.0/16"

CALICO_MANIFEST_URL="https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml"

# Wait / timeout parameters
WAIT_NODE_READY_SEC=180
WAIT_CNI_FILE_SEC=120

# CNI file (Calico)
CNI_CONF_DIR="/etc/cni/net.d"
CALICO_CNI_CONFLIST="${CNI_CONF_DIR}/10-calico.conflist"

# =========================
# Utils
# =========================
log() { echo "[$(date +'%F %T')] $*"; }
die() { log "❌ $*"; exit 1; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "Run as root: sudo $0"
  fi
}

detect_current_user() {
  local u
  u="$(logname 2>/dev/null || true)"
  if [[ -z "$u" || "$u" == "root" ]]; then
    u="${SUDO_USER:-ubuntu}"
  fi
  echo "$u"
}

get_master_ip() {
  hostname -I | awk '{print $1}'
}

# =========================
# System Prep
# =========================
ensure_deps() {
  log ">>> Install dependencies (curl / net-tools / iptables / crictl)"
  apt-get update -y
  apt-get install -y curl net-tools iptables
  # crictl sometimes already included; missing is not fatal
  command -v crictl >/dev/null 2>&1 || true
}

ensure_sysctl() {
  log ">>> Configure kernel parameters (br_netfilter / ip_forward)"
  modprobe br_netfilter || true
  cat >/etc/sysctl.d/99-kubernetes.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sysctl --system >/dev/null
}

disable_swap() {
  log ">>> Disable swap"
  swapoff -a || true
  sed -i '/\sswap\s/ s/^/#/' /etc/fstab || true
}

# =========================
# Hard Reset (make every run clean)
# =========================
hard_reset_all() {
  log ">>> HARD RESET: completely clean Kubernetes/network/certs/kubeconfig (start fresh every run)"

  # 1. Stop and mask kubelet (prevent auto-start of static pods)
  log ">>> 1. Stop and mask kubelet (prevent auto-start of static pods)..."
  systemctl stop kubelet 2>/dev/null || log "  kubelet not running or already stopped"
  systemctl disable kubelet 2>/dev/null || true
  systemctl mask kubelet 2>/dev/null || true

  # Stop other services (but not containerd, restart later)
  log ">>> 1.1 Stop docker (containerd restart later)..."
  systemctl stop docker 2>/dev/null || log "  docker not running or already stopped"

  # 2. Kill all Kubernetes related processes (critical step)
  log ">>> 2. Kill all Kubernetes related processes..."
  pkill -9 kube-apiserver 2>/dev/null || log "  kube-apiserver process not found"
  pkill -9 kube-controller-manager 2>/dev/null || log "  kube-controller-manager process not found"
  pkill -9 kube-scheduler 2>/dev/null || log "  kube-scheduler process not found"
  pkill -9 kube-proxy 2>/dev/null || log "  kube-proxy process not found"
  pkill -9 etcd 2>/dev/null || log "  etcd process not found"

  # 3. Delete static pod manifests (prevent kubelet from reviving them)
  log ">>> 3. Delete static pod manifests..."
  rm -rf /etc/kubernetes/manifests/* 2>/dev/null || log "  manifests directory not found or already empty"

  # 4. Wait for processes to terminate fully
  sleep 2

  # 5. kubeadm reset (should be safe now)
  log ">>> 4. Run kubeadm reset..."
  kubeadm reset -f || {
    log "⚠️  kubeadm reset encountered error, continuing cleanup..."
  }

  # 6. Clear k8s state data
  log ">>> 5. Clear Kubernetes state data..."
  rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd || true

  # 7. Clean CNI / Calico remnants
  log ">>> 6. Clean CNI / Calico remnants..."
  rm -rf /var/run/calico /etc/cni/net.d /opt/cni/bin /var/lib/cni /var/lib/calico || true

  # 8. Clean kubeconfig (critical: avoid old certs causing x509 unknown authority)
  log ">>> 7. Clean kubeconfig..."
  rm -rf /root/.kube || true
  rm -rf /home/*/.kube || true

  # 9. Restart containerd and ensure socket is ready (prepare for clean init)
  log ">>> 8. Reload systemd and restart containerd..."
  systemctl daemon-reexec 2>/dev/null || log "  daemon-reexec complete"
  systemctl daemon-reload
  systemctl restart containerd || log "  containerd restart failed (may not be installed)"
  systemctl enable containerd 2>/dev/null || true

  # 9.1 Wait for containerd socket to be ready (critical)
  log ">>> 8.1 Wait for containerd socket to be ready..."
  local end=$((SECONDS + 30))
  while [ $SECONDS -lt $end ]; do
    [[ -S /var/run/containerd/containerd.sock ]] && break
    sleep 1
  done
  [[ -S /var/run/containerd/containerd.sock ]] || die "containerd.sock missing: /var/run/containerd/containerd.sock"

  # 10. Final port check (optional, but helps with diagnosis)
  log ">>> 9. Check if critical ports are released..."
  if command -v ss >/dev/null 2>&1; then
    if ss -lntp | grep -qE ':(6443|2379|2380)\b'; then
      log "  ⚠️  Ports still in use:"
      ss -lntp | grep -E ':(6443|2379|2380)\b' || true
    else
      log "  ✔ Critical ports released (6443, 2379, 2380)"
    fi
  else
    log "  ss not installed, skip port check"
  fi

  log ">>> HARD RESET complete"
}

# =========================
# kubeadm init + kubeconfig
# =========================
# =========================
# kubeadm init + kubeconfig
# =========================

kubeadm_init() {
  local master_ip="$1"

  # Unmask kubelet before init (now safe to start)
  log ">>> Prepare kubeadm init: unmask and start kubelet..."
  systemctl unmask kubelet 2>/dev/null || true
  systemctl enable kubelet 2>/dev/null || true
  systemctl start kubelet 2>/dev/null || true

  log ">>> kubeadm init (node=${NODE_NAME}, endpoint=${master_ip})"
  kubeadm init \
    --node-name="${NODE_NAME}" \
    --pod-network-cidr="${POD_CIDR}" \
    --control-plane-endpoint="${master_ip}"
}

setup_kubeconfig_root() {
  log ">>> Configure kubectl (root)"
  mkdir -p /root/.kube
  cp -f /etc/kubernetes/admin.conf /root/.kube/config
  export KUBECONFIG=/root/.kube/config
}

remove_controlplane_taint() {
  log ">>> Ensure control-plane taint removed (single-node cluster)"
  kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || true
  kubectl taint nodes --all node-role.kubernetes.io/master:NoSchedule- 2>/dev/null || true
}



setup_kubeconfig_user() {
  local user="$1"
  local home
  home="$(eval echo "~${user}")"
  log ">>> Configure kubectl (user: ${user}, home=${home})"
  mkdir -p "${home}/.kube"
  cp -f /etc/kubernetes/admin.conf "${home}/.kube/config"
  chown -R "${user}:${user}" "${home}/.kube"
}

# =========================
# CNI (Calico)
# =========================
install_calico() {
  log ">>> Install Calico CNI"
  kubectl apply -f "${CALICO_MANIFEST_URL}"
}

wait_for_cni_file() {
  log ">>> Wait for Calico to write CNI config: ${CALICO_CNI_CONFLIST}"
  local end=$((SECONDS + WAIT_CNI_FILE_SEC))
  while [ $SECONDS -lt $end ]; do
    [[ -f "${CALICO_CNI_CONFLIST}" ]] && { log "✔ CNI config appeared"; return 0; }
    sleep 2
  done
  log "⚠️  CNI conflist not found within timeout (continuing, Node Ready may still succeed)"
  return 0
}

kick_cri_and_kubelet() {
  log ">>> Restart containerd + kubelet"
  systemctl restart containerd || true
  systemctl restart kubelet || true
}

wait_for_node_ready() {
  log ">>> Wait for Node Ready"
  local end=$((SECONDS + WAIT_NODE_READY_SEC))
  while [ $SECONDS -lt $end ]; do
    if kubectl get nodes "${NODE_NAME}" 2>/dev/null | awk 'NR==2{print $2}' | grep -q '^Ready$'; then
      log "✔ Node is Ready"
      return 0
    fi
    sleep 2
  done
  log "⚠️  Node not Ready within timeout (printing diagnostics)"
  kubectl get nodes -o wide || true
  kubectl describe node "${NODE_NAME}" | sed -n '/Conditions:/,/Addresses:/p' || true
  return 1
}

remove_controlplane_taint_for_single_node() {
  log ">>> Single node: remove control-plane taint"
  kubectl taint nodes "${NODE_NAME}" node-role.kubernetes.io/control-plane:NoSchedule- || true
  kubectl taint nodes "${NODE_NAME}" node-role.kubernetes.io/master:NoSchedule- || true
}

# =========================
# Join command
# =========================
print_join_cmd() {
  log ">>> Join command (for workers)"
  kubeadm token create --print-join-command
}

# =========================
# Main
# =========================
need_root

log "===== system node: one-click reset and rebuild (start fresh every run) ====="

ensure_deps
ensure_sysctl
disable_swap

hard_reset_all

MASTER_IP="$(get_master_ip)"
log ">>> Using master node IP: ${MASTER_IP}"

kubeadm_init "${MASTER_IP}"
setup_kubeconfig_root

# user kubeconfig (write early, avoid manual cert fixes later)
CURRENT_USER="$(detect_current_user)"
setup_kubeconfig_user "${CURRENT_USER}"

# CNI
install_calico
wait_for_cni_file
kick_cri_and_kubelet
wait_for_node_ready || true

remove_controlplane_taint_for_single_node

print_join_cmd

log "===== Done ====="
log ">>> Check: kubectl get nodes && kubectl get pods -A"
