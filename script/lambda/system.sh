#!/usr/bin/env bash
# =====================================================================
# Lambda Labs A100 — kubeadm init / hard reset (system.sh)
# ---------------------------------------------------------------------
# Differences from script/laptop/system.sh:
#   - Only one: when selecting master IP, prefer private IP on eno1
#     (10.19.28.61), not relying on hostname -I order.
#     Lambda ifconfig usually has only one non-loopback IP, but explicitly
#     choosing eno1 is more stable.
#
# NODE_NAME remains "system" — aligns with nodeSelector/labels in all manifests,
# do not change. kubeadm --node-name overrides hostname (Lambda default hostname
# is "161-153-48-3"; pure digits + hyphens not liked by some tools).
# =====================================================================
set -euo pipefail

# =========================
# Config
# =========================
NODE_NAME="system"
POD_CIDR="192.168.0.0/16"

CALICO_MANIFEST_URL="https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml"

WAIT_NODE_READY_SEC=180
WAIT_CNI_FILE_SEC=120

CNI_CONF_DIR="/etc/cni/net.d"
CALICO_CNI_CONFLIST="${CNI_CONF_DIR}/10-calico.conflist"

# =========================
# Utils
# =========================
log() { echo "[$(date +'%F %T')] $*"; }
die() { log "❌ $*"; exit 1; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "Must run as root: sudo $0"
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

# Lambda: prefer the IP on the primary egress interface (the one routing
# to the internet). On this box that's eno1 = 10.19.28.61.
# Falls back to the first hostname -I entry if route lookup fails.
get_master_ip() {
  local ip
  ip="$(ip -o -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
  if [[ -z "$ip" ]]; then
    ip="$(hostname -I | awk '{print $1}')"
  fi
  echo "$ip"
}

# =========================
# System Prep
# =========================
ensure_deps() {
  log ">>> Install dependencies (curl / net-tools / iptables / crictl)"
  apt-get update -y
  apt-get install -y curl net-tools iptables
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
# Hard Reset
# =========================
hard_reset_all() {
  log ">>> HARD RESET: completely clean up Kubernetes/network/certs/kubeconfig"

  log ">>> 1. Stop and mask kubelet"
  systemctl stop kubelet 2>/dev/null || log "  kubelet not running or already stopped"
  systemctl disable kubelet 2>/dev/null || true
  systemctl mask kubelet 2>/dev/null || true

  log ">>> 1.1 Stop docker (containerd will restart later)"
  systemctl stop docker 2>/dev/null || log "  docker not running or already stopped"

  log ">>> 2. Kill all Kubernetes-related processes"
  pkill -9 kube-apiserver 2>/dev/null || log "  kube-apiserver process not found"
  pkill -9 kube-controller-manager 2>/dev/null || log "  kube-controller-manager process not found"
  pkill -9 kube-scheduler 2>/dev/null || log "  kube-scheduler process not found"
  pkill -9 kube-proxy 2>/dev/null || log "  kube-proxy process not found"
  pkill -9 etcd 2>/dev/null || log "  etcd process not found"

  log ">>> 3. Delete static pod manifests"
  rm -rf /etc/kubernetes/manifests/* 2>/dev/null || log "  manifests directory not found or already empty"

  sleep 2

  log ">>> 4. Execute kubeadm reset"
  kubeadm reset -f || log "⚠️  kubeadm reset encountered error, continue cleanup..."

  log ">>> 5. Clear Kubernetes state data"
  rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd || true

  log ">>> 6. Clean up CNI / Calico remnants"
  rm -rf /var/run/calico /etc/cni/net.d /opt/cni/bin /var/lib/cni /var/lib/calico || true

  log ">>> 7. Clean up kubeconfig"
  rm -rf /root/.kube || true
  rm -rf /home/*/.kube || true

  log ">>> 8. Reload systemd and restart containerd"
  systemctl daemon-reexec 2>/dev/null || log "  daemon-reexec completed"
  systemctl daemon-reload
  systemctl restart containerd || log "  containerd restart failed (may not be installed)"
  systemctl enable containerd 2>/dev/null || true

  log ">>> 8.1 Wait for containerd socket ready"
  local end=$((SECONDS + 30))
  while [ $SECONDS -lt $end ]; do
    [[ -S /var/run/containerd/containerd.sock ]] && break
    sleep 1
  done
  [[ -S /var/run/containerd/containerd.sock ]] || die "containerd.sock not found"

  log ">>> 9. Check critical ports"
  if command -v ss >/dev/null 2>&1; then
    if ss -lntp | grep -qE ':(6443|2379|2380)\b'; then
      log "  ⚠️  ports still in use:"
      ss -lntp | grep -E ':(6443|2379|2380)\b' || true
    else
      log "  ✔ critical ports released (6443, 2379, 2380)"
    fi
  fi

  log ">>> HARD RESET complete"
}

# =========================
# kubeadm init + kubeconfig
# =========================
kubeadm_init() {
  local master_ip="$1"

  log ">>> Prepare kubeadm init: unmask and start kubelet"
  systemctl unmask kubelet 2>/dev/null || true
  systemctl enable kubelet 2>/dev/null || true
  systemctl start kubelet 2>/dev/null || true

  log ">>> kubeadm init (node=${NODE_NAME}, advertise-addr=${master_ip})"
  # --apiserver-advertise-address forces binding to private IP, don't let kubeadm guess.
  # --control-plane-endpoint uses same private IP — we expose ingress via NAT later
  # (port 80), k8s API server should not use public.
  kubeadm init \
    --node-name="${NODE_NAME}" \
    --pod-network-cidr="${POD_CIDR}" \
    --apiserver-advertise-address="${master_ip}" \
    --control-plane-endpoint="${master_ip}"
}

setup_kubeconfig_root() {
  log ">>> Configure kubectl (root)"
  mkdir -p /root/.kube
  cp -f /etc/kubernetes/admin.conf /root/.kube/config
  export KUBECONFIG=/root/.kube/config
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
  log "⚠️  CNI conflist not found within timeout"
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
      log "✔ Node Ready"
      return 0
    fi
    sleep 2
  done
  log "⚠️  Node not Ready within timeout"
  kubectl get nodes -o wide || true
  kubectl describe node "${NODE_NAME}" | sed -n '/Conditions:/,/Addresses:/p' || true
  return 1
}

remove_controlplane_taint_for_single_node() {
  log ">>> Single node: remove control-plane taint"
  kubectl taint nodes "${NODE_NAME}" node-role.kubernetes.io/control-plane:NoSchedule- || true
  kubectl taint nodes "${NODE_NAME}" node-role.kubernetes.io/master:NoSchedule- || true
}

print_join_cmd() {
  log ">>> join command (for multi-node expansion; ignore for single node)"
  kubeadm token create --print-join-command || true
}

# =========================
# Main
# =========================
need_root

log "===== Lambda A100 node: one-command reset and rebuild ====="

ensure_deps
ensure_sysctl
disable_swap

hard_reset_all

MASTER_IP="$(get_master_ip)"
log ">>> Using master node IP: ${MASTER_IP}"

kubeadm_init "${MASTER_IP}"
setup_kubeconfig_root

CURRENT_USER="$(detect_current_user)"
setup_kubeconfig_user "${CURRENT_USER}"

install_calico
wait_for_cni_file
kick_cri_and_kubelet
wait_for_node_ready || true

remove_controlplane_taint_for_single_node

print_join_cmd

log "===== Complete ====="
log ">>> Verify: kubectl get nodes && kubectl get pods -A"
