#!/bin/bash
set -euo pipefail

# =========================
# Config
# =========================
NODE_NAME="system"
POD_CIDR="192.168.0.0/16"
CALICO_MANIFEST_URL="https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml"
METALLB_CONFIG="/home/ubuntu/k8s/llm-deployment/control/config/k8s/base/metallb/metallb-ip-pool.yaml"

CNI_CONF_DIR="/etc/cni/net.d"
CALICO_CNI_CONFLIST="${CNI_CONF_DIR}/10-calico.conflist"

log() { echo -e "[$(date +'%F %T')] $*"; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    log "❌ 请用 root 运行：sudo $0"
    exit 1
  fi
}

# Best-effort current user for kubeconfig copy (non-root)
detect_current_user() {
  local u
  u="$(logname 2>/dev/null || true)"
  if [ -z "${u}" ] || [ "${u}" = "root" ]; then
    u="${SUDO_USER:-}"
  fi
  if [ -z "${u}" ] || [ "${u}" = "root" ]; then
    # fallback
    u="ubuntu"
  fi
  echo "${u}"
}

get_public_ip() {
  curl -s --max-time 5 ifconfig.me || true
}

get_master_ip() {
  hostname -I | awk '{print $1}'
}

ensure_sysctl() {
  log ">>> 配置内核参数（br_netfilter / ip_forward）"
  modprobe br_netfilter || true
  cat >/etc/sysctl.d/99-kubernetes-cri.conf <<'EOF'
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

ensure_containerd_systemd_cgroup() {
  log ">>> 检查并修复 containerd: SystemdCgroup = true"
  mkdir -p /etc/containerd

  if [ ! -f /etc/containerd/config.toml ]; then
    containerd config default >/etc/containerd/config.toml
  fi

  if grep -qE '^\s*SystemdCgroup\s*=\s*true\s*$' /etc/containerd/config.toml; then
    log ">>> containerd cgroup 已正确配置"
    return 0
  fi

  # make sure the setting exists and is true
  if grep -qE '^\s*SystemdCgroup\s*=\s*false\s*$' /etc/containerd/config.toml; then
    sed -i 's/^\(\s*SystemdCgroup\s*=\s*\)false\s*$/\1true/' /etc/containerd/config.toml
  else
    # insert under runc options if missing
    awk '
      {print}
      /^\s*\[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\.runc\.options\]\s*$/{
        found=1
      }
      found==1 && inserted!=1 && /^\s*$/{
        print "            SystemdCgroup = true"
        inserted=1
      }
    ' /etc/containerd/config.toml > /tmp/config.toml && mv /tmp/config.toml /etc/containerd/config.toml
    # if awk insertion didn't happen, still try a direct append (safe)
    if ! grep -qE '^\s*SystemdCgroup\s*=\s*true\s*$' /etc/containerd/config.toml; then
      echo "            SystemdCgroup = true" >> /etc/containerd/config.toml
    fi
  fi

  systemctl daemon-reload || true
  systemctl restart containerd
  systemctl restart kubelet || true
  log ">>> containerd/kubelet 已重启以应用 cgroup 配置"
}

clean_kubeadm_state() {
  log ">>> 清理旧 kubeadm 状态（可重复运行）"
  kubeadm reset -f || true

  rm -rf /etc/kubernetes/manifests /etc/kubernetes/pki || true
  rm -rf /var/lib/etcd || true

  # CNI leftovers
  rm -rf /etc/cni/net.d || true

  # kubeconfig leftovers for root
  rm -rf /root/.kube || true
}

ensure_deps() {
  log ">>> 安装依赖（net-tools / curl）"
  apt-get update -y
  apt-get install -y net-tools curl
}

patch_metallb_ip_pool() {
  local pubip="$1"
  if [ -z "${pubip}" ]; then
    log "⚠️  未获取到公网 IP，跳过 metallb-ip-pool.yaml 替换"
    return 0
  fi

  if [ -f "${METALLB_CONFIG}" ]; then
    log ">>> 替换 metallb-ip-pool.yaml 中 PUBLIC_IP -> ${pubip}"
    sed -i "s|PUBLIC_IP|${pubip}|g" "${METALLB_CONFIG}"
    log "✔ Modified metallb-ip-pool.yaml"
  else
    log "⚠️  未找到 ${METALLB_CONFIG}，跳过 IP 替换"
  fi
}

kubeadm_init() {
  local master_ip="$1"
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

install_calico() {
  log ">>> 安装 Calico CNI"
  kubectl apply -f "${CALICO_MANIFEST_URL}"
}

wait_for_cni_file() {
  log ">>> 等待 Calico 写入 CNI 配置：${CALICO_CNI_CONFLIST}"
  local i
  for i in $(seq 1 60); do
    if [ -f "${CALICO_CNI_CONFLIST}" ]; then
      log "✔ CNI 配置已存在"
      return 0
    fi
    sleep 2
  done

  log "❌ 超时：未发现 ${CALICO_CNI_CONFLIST}"
  ls -la "${CNI_CONF_DIR}" || true
  return 1
}

kick_cri_and_kubelet() {
  log ">>> 重启 containerd + kubelet（触发重新加载 CNI）"
  systemctl restart containerd
  systemctl restart kubelet
}

wait_for_cri_network_ready() {
  log ">>> 等待 CRI NetworkReady / lastCNILoadStatus=OK"
  local i out
  for i in $(seq 1 60); do
    out="$(crictl info 2>/dev/null | grep -nE '"NetworkReady"|lastCNILoadStatus' || true)"
    if echo "${out}" | grep -q 'lastCNILoadStatus": "OK"'; then
      log "✔ CRI lastCNILoadStatus=OK"
      return 0
    fi
    sleep 2
  done

  log "❌ 超时：CRI 仍未 OK"
  crictl info | head -n 260 || true
  return 1
}

wait_for_node_ready() {
  log ">>> 等待 Node Ready"
  local i
  for i in $(seq 1 60); do
    if kubectl get nodes "${NODE_NAME}" 2>/dev/null | awk 'NR==2{print $2}' | grep -q '^Ready$'; then
      log "✔ Node 已 Ready"
      return 0
    fi
    sleep 2
  done

  log "⚠️  Node 未在超时内 Ready（但会继续打印诊断信息）"
  kubectl describe node "${NODE_NAME}" | sed -n '/Conditions:/,/Addresses:/p' || true
  return 1
}

remove_controlplane_taint_for_single_node() {
  log ">>> 单节点集群：移除 control-plane taint（允许调度工作负载）"
  kubectl taint nodes "${NODE_NAME}" node-role.kubernetes.io/control-plane:NoSchedule- || true
  kubectl taint nodes "${NODE_NAME}" node-role.kubernetes.io/master:NoSchedule- || true
}

print_join_cmd() {
  log ">>> 生成 join 命令（worker 用）"
  kubeadm token create --print-join-command
}

# =========================
# Main
# =========================
need_root

log "===== system 节点稳态初始化开始（可反复运行）====="

ensure_deps

PUBIP="$(get_public_ip)"
log ">>> 公网 IP: ${PUBIP:-<empty>}"
patch_metallb_ip_pool "${PUBIP}"

ensure_sysctl
disable_swap
ensure_containerd_systemd_cgroup

clean_kubeadm_state

MASTER_IP="$(get_master_ip)"
log ">>> 使用主节点 IP: ${MASTER_IP}"

kubeadm_init "${MASTER_IP}"
setup_kubeconfig_root

# kubectl now available
install_calico

# Critical: wait for calico to write CNI file, then restart CRI/kubelet and wait for CRI status OK
wait_for_cni_file
kick_cri_and_kubelet
wait_for_cri_network_ready

# After CRI OK, node should become Ready shortly
wait_for_node_ready || true

remove_controlplane_taint_for_single_node
print_join_cmd

# copy kubeconfig to non-root user
CURRENT_USER="$(detect_current_user)"
setup_kubeconfig_user "${CURRENT_USER}"

log "===== system 节点稳态初始化完成 ====="
log ">>> 快速检查：kubectl get nodes && kubectl get pods -A"

