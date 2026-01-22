#!/usr/bin/env bash
set -euo pipefail

# =========================
# Config
# =========================
NODE_NAME="system"
POD_CIDR="192.168.0.0/16"

CALICO_MANIFEST_URL="https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml"
METALLB_MANIFEST_URL="https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb-native.yaml"

METALLB_CONFIG="/home/ubuntu/k8s/llm-deployment/control/config/k8s/base/metallb/metallb-ip-pool.yaml"

IFACE="eno1"
PORTS="80,443"

CNI_CONF_DIR="/etc/cni/net.d"
CALICO_CNI_CONFLIST="${CNI_CONF_DIR}/10-calico.conflist"

log() { echo "[$(date '+%F %T')] $*"; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    log "❌ 请用 root 运行：sudo $0"
    exit 1
  fi
}

detect_current_user() {
  local u
  u="$(logname 2>/dev/null || true)"
  [[ -z "$u" || "$u" == "root" ]] && u="${SUDO_USER:-ubuntu}"
  echo "$u"
}

get_public_ip() {
  curl -s --max-time 5 ifconfig.me || true
}

get_master_ip() {
  hostname -I | awk '{print $1}'
}

ensure_sysctl() {
  log ">>> 配置内核参数"
  modprobe br_netfilter || true
  cat >/etc/sysctl.d/99-kubernetes.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sysctl --system >/dev/null
}

disable_swap() {
  log ">>> 关闭 swap"
  swapoff -a || true
  sed -i '/\sswap\s/ s/^/#/' /etc/fstab || true
}

ensure_deps() {
  log ">>> 安装依赖"
  apt-get update -y
  apt-get install -y curl net-tools
}

clean_kubeadm_state() {
  log ">>> 清理 kubeadm 状态"
  kubeadm reset -f || true
  rm -rf /etc/kubernetes /var/lib/etcd /etc/cni/net.d /root/.kube || true
}

kubeadm_init() {
  local ip="$1"
  log ">>> kubeadm init"
  kubeadm init \
    --node-name="${NODE_NAME}" \
    --pod-network-cidr="${POD_CIDR}" \
    --control-plane-endpoint="${ip}"
}

setup_kubeconfig_root() {
  mkdir -p /root/.kube
  cp /etc/kubernetes/admin.conf /root/.kube/config
}

setup_kubeconfig_user() {
  local u="$1"
  local h
  h="$(eval echo "~${u}")"
  mkdir -p "${h}/.kube"
  cp /etc/kubernetes/admin.conf "${h}/.kube/config"
  chown -R "${u}:${u}" "${h}/.kube"
}

install_calico() {
  kubectl apply -f "${CALICO_MANIFEST_URL}"
}

wait_for_cni_file() {
  for _ in {1..60}; do
    [[ -f "${CALICO_CNI_CONFLIST}" ]] && return 0
    sleep 2
  done
  return 1
}

kick_cri_and_kubelet() {
  systemctl restart containerd kubelet
}

wait_for_node_ready() {
  for _ in {1..60}; do
    kubectl get nodes "${NODE_NAME}" 2>/dev/null | grep -q Ready && return 0
    sleep 2
  done
  return 1
}

install_metallb() {
  kubectl apply -f "${METALLB_MANIFEST_URL}"
}

wait_for_metallb_ready() {
  kubectl rollout status -n metallb-system deploy/controller --timeout=180s
  kubectl rollout status -n metallb-system ds/speaker --timeout=180s
}

# =========================
# ✅ 修复后的函数（关键）
# =========================
generate_virtual_ip() {
  echo ">>> Detect node IP from interface: ${IFACE}" >&2

  local node_ip prefix candidate

  node_ip=$(ip -4 addr show dev "$IFACE" | awk '/inet /{print $2}' | cut -d/ -f1)
  [[ -z "$node_ip" ]] && return 1

  echo "✔ Node IP: ${node_ip}" >&2

  prefix=$(echo "$node_ip" | cut -d. -f1-3)
  echo "✔ IP prefix: ${prefix}.x" >&2
  echo ">>> Searching free virtual IP in ${prefix}.200–250" >&2

  for i in $(seq 200 250); do
    candidate="${prefix}.${i}"
    [[ "$candidate" == "$node_ip" ]] && continue
    if ! ping -c1 -W1 "$candidate" &>/dev/null; then
      echo "$candidate"      # ✅ 只输出 IP
      return 0
    fi
  done

  return 1
}

apply_metallb_ip_pool() {
  local vip="$1"
  sed -i "s|VIRTUAL_IP|${vip}|g" "${METALLB_CONFIG}"
  kubectl apply -f "${METALLB_CONFIG}"
}

setup_nat() {
  local pub="$1"
  local vip="$2"

  sysctl -w net.ipv4.ip_forward=1 >/dev/null

  iptables -t nat -D PREROUTING -d "$pub" -p tcp -m multiport --dports "$PORTS" \
    -j DNAT --to-destination "$vip" 2>/dev/null || true

  iptables -t nat -D POSTROUTING -d "$vip" -p tcp -m multiport --dports "$PORTS" \
    -j MASQUERADE 2>/dev/null || true

  iptables -t nat -A PREROUTING \
    -d "$pub" -p tcp -m multiport --dports "$PORTS" \
    -j DNAT --to-destination "$vip"

  iptables -t nat -A POSTROUTING \
    -d "$vip" -p tcp -m multiport --dports "$PORTS" \
    -j MASQUERADE
}

# =========================
# Main
# =========================
need_root
ensure_deps
ensure_sysctl
disable_swap
clean_kubeadm_state

MASTER_IP="$(get_master_ip)"
kubeadm_init "${MASTER_IP}"
setup_kubeconfig_root

install_calico
wait_for_cni_file
kick_cri_and_kubelet
wait_for_node_ready || true

install_metallb
wait_for_metallb_ready

VIRTUAL_IP="$(generate_virtual_ip)"
log "✔ Selected MetalLB virtual IP: ${VIRTUAL_IP}"
apply_metallb_ip_pool "${VIRTUAL_IP}"

PUBLIC_IP="$(get_public_ip)"
log "✔ Public IP: ${PUBLIC_IP}"
setup_nat "${PUBLIC_IP}" "${VIRTUAL_IP}"

CURRENT_USER="$(detect_current_user)"
setup_kubeconfig_user "${CURRENT_USER}"

log "===== 完成 ====="
