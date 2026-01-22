#!/usr/bin/env bash
set -euo pipefail

# =========================
# Config
# =========================
NODE_NAME="system"
POD_CIDR="192.168.0.0/16"

CALICO_MANIFEST_URL="https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml"

# 等待/超时参数
WAIT_NODE_READY_SEC=180
WAIT_CNI_FILE_SEC=120

# CNI 文件（Calico）
CNI_CONF_DIR="/etc/cni/net.d"
CALICO_CNI_CONFLIST="${CNI_CONF_DIR}/10-calico.conflist"

# =========================
# Utils
# =========================
log() { echo "[$(date +'%F %T')] $*"; }
die() { log "❌ $*"; exit 1; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "请用 root 运行：sudo $0"
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
  log ">>> 安装依赖（curl / net-tools / iptables / crictl）"
  apt-get update -y
  apt-get install -y curl net-tools iptables
  # crictl 有时已自带；没有也不致命
  command -v crictl >/dev/null 2>&1 || true
}

ensure_sysctl() {
  log ">>> 配置内核参数（br_netfilter / ip_forward）"
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

# =========================
# Hard Reset (make every run clean)
# =========================
hard_reset_all() {
  log ">>> HARD RESET: 彻底清理 Kubernetes/网络/证书/kubeconfig（每次运行都重来）"

  # 1. 停止并 mask kubelet（防止它自动拉起 static pod）
  log ">>> 1. 停止并 mask kubelet（防止自动拉起 static pod）..."
  systemctl stop kubelet 2>/dev/null || log "  kubelet 未运行或已停止"
  systemctl disable kubelet 2>/dev/null || true
  systemctl mask kubelet 2>/dev/null || true
  
  # 停止其他服务（但不停止 containerd，后面会 restart）
  log ">>> 1.1 停止 docker（containerd 稍后 restart）..."
  systemctl stop docker 2>/dev/null || log "  docker 未运行或已停止"

  # 2. 杀掉所有 Kubernetes 相关进程（关键一步）
  log ">>> 2. 杀掉所有 Kubernetes 相关进程..."
  pkill -9 kube-apiserver 2>/dev/null || log "  kube-apiserver 进程不存在"
  pkill -9 kube-controller-manager 2>/dev/null || log "  kube-controller-manager 进程不存在"
  pkill -9 kube-scheduler 2>/dev/null || log "  kube-scheduler 进程不存在"
  pkill -9 kube-proxy 2>/dev/null || log "  kube-proxy 进程不存在"
  pkill -9 etcd 2>/dev/null || log "  etcd 进程不存在"

  # 3. 删除 static pod manifests（防止 kubelet 复活它们）
  log ">>> 3. 删除 static pod manifests..."
  rm -rf /etc/kubernetes/manifests/* 2>/dev/null || log "  manifests 目录不存在或已清空"

  # 4. 等待进程完全终止
  sleep 2

  # 5. kubeadm reset（现在应该可以安全执行）
  log ">>> 4. 执行 kubeadm reset..."
  kubeadm reset -f || {
    log "⚠️  kubeadm reset 遇到错误，继续清理..."
  }

  # 6. 清空 k8s 状态数据
  log ">>> 5. 清空 Kubernetes 状态数据..."
  rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd || true

  # 7. 清 CNI / Calico 残留
  log ">>> 6. 清理 CNI / Calico 残留..."
  rm -rf /var/run/calico /etc/cni/net.d /opt/cni/bin /var/lib/cni /var/lib/calico || true

  # 8. 清理 kubeconfig（关键：避免旧证书导致 x509 unknown authority）
  log ">>> 7. 清理 kubeconfig..."
  rm -rf /root/.kube || true
  rm -rf /home/*/.kube || true

  # 9. 重新启动 containerd 并确保 socket 就绪（准备干净 init）
  log ">>> 8. 重新加载 systemd 并重启 containerd..."
  systemctl daemon-reexec 2>/dev/null || log "  daemon-reexec 执行完成"
  systemctl daemon-reload
  systemctl restart containerd || log "  containerd 重启失败（可能未安装）"
  systemctl enable containerd 2>/dev/null || true
  
  # 9.1 等待 containerd socket 就绪（关键）
  log ">>> 8.1 等待 containerd socket 就绪..."
  local end=$((SECONDS + 30))
  while [ $SECONDS -lt $end ]; do
    [[ -S /var/run/containerd/containerd.sock ]] && break
    sleep 1
  done
  [[ -S /var/run/containerd/containerd.sock ]] || die "containerd.sock 不存在：/var/run/containerd/containerd.sock"

  # 10. 最终确认端口（可选，但有助于诊断）
  log ">>> 9. 检查关键端口是否已释放..."
  if command -v ss >/dev/null 2>&1; then
    if ss -lntp | grep -qE ':(6443|2379|2380)\b'; then
      log "  ⚠️  端口仍被占用："
      ss -lntp | grep -E ':(6443|2379|2380)\b' || true
    else
      log "  ✔ 关键端口已释放（6443, 2379, 2380）"
    fi
  else
    log "  ss 未安装，跳过端口检查"
  fi

  log ">>> HARD RESET 完成"
}

# =========================
# kubeadm init + kubeconfig
# =========================
# =========================
# kubeadm init + kubeconfig
# =========================

kubeadm_init() {
  local master_ip="$1"
  
  # 在 init 之前 unmask kubelet（现在可以安全启动）
  log ">>> 准备 kubeadm init：unmask 并启动 kubelet..."
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
  log ">>> 配置 kubectl（root）"
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
  log ">>> 配置 kubectl（用户：${user}, home=${home}）"
  mkdir -p "${home}/.kube"
  cp -f /etc/kubernetes/admin.conf "${home}/.kube/config"
  chown -R "${user}:${user}" "${home}/.kube"
}

# =========================
# CNI (Calico)
# =========================
install_calico() {
  log ">>> 安装 Calico CNI"
  kubectl apply -f "${CALICO_MANIFEST_URL}"
}

wait_for_cni_file() {
  log ">>> 等待 Calico 写入 CNI 配置：${CALICO_CNI_CONFLIST}"
  local end=$((SECONDS + WAIT_CNI_FILE_SEC))
  while [ $SECONDS -lt $end ]; do
    [[ -f "${CALICO_CNI_CONFLIST}" ]] && { log "✔ CNI 配置已出现"; return 0; }
    sleep 2
  done
  log "⚠️  未在超时时间内发现 CNI conflist（继续执行，后续 Node Ready 可能仍会成功）"
  return 0
}

kick_cri_and_kubelet() {
  log ">>> 重启 containerd + kubelet"
  systemctl restart containerd || true
  systemctl restart kubelet || true
}

wait_for_node_ready() {
  log ">>> 等待 Node Ready"
  local end=$((SECONDS + WAIT_NODE_READY_SEC))
  while [ $SECONDS -lt $end ]; do
    if kubectl get nodes "${NODE_NAME}" 2>/dev/null | awk 'NR==2{print $2}' | grep -q '^Ready$'; then
      log "✔ Node 已 Ready"
      return 0
    fi
    sleep 2
  done
  log "⚠️  Node 未在超时时间内 Ready（打印诊断）"
  kubectl get nodes -o wide || true
  kubectl describe node "${NODE_NAME}" | sed -n '/Conditions:/,/Addresses:/p' || true
  return 1
}

remove_controlplane_taint_for_single_node() {
  log ">>> 单节点：移除 control-plane taint"
  kubectl taint nodes "${NODE_NAME}" node-role.kubernetes.io/control-plane:NoSchedule- || true
  kubectl taint nodes "${NODE_NAME}" node-role.kubernetes.io/master:NoSchedule- || true
}

# =========================
# Join command
# =========================
print_join_cmd() {
  log ">>> join 命令（worker 用）"
  kubeadm token create --print-join-command
}

# =========================
# Main
# =========================
need_root

log "===== system 节点：一键重置并重建（每次运行都清空再来）====="

ensure_deps
ensure_sysctl
disable_swap

hard_reset_all

MASTER_IP="$(get_master_ip)"
log ">>> 使用主节点 IP: ${MASTER_IP}"

kubeadm_init "${MASTER_IP}"
setup_kubeconfig_root

# user kubeconfig（提前写，避免后续手动修证书）
CURRENT_USER="$(detect_current_user)"
setup_kubeconfig_user "${CURRENT_USER}"

# CNI
install_calico
wait_for_cni_file
kick_cri_and_kubelet
wait_for_node_ready || true

remove_controlplane_taint_for_single_node

print_join_cmd

log "===== 完成 ====="
log ">>> 检查：kubectl get nodes && kubectl get pods -A"
