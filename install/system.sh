#!/usr/bin/env bash
set -euo pipefail

# =========================
# Config
# =========================
NODE_NAME="system"
POD_CIDR="192.168.0.0/16"

CALICO_MANIFEST_URL="https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml"
METALLB_MANIFEST_URL="https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb-native.yaml"

# MetalLB IP pool 模板文件：必须包含占位符 VIRTUAL_IP，例如： - VIRTUAL_IP/32
METALLB_CONFIG="/home/ubuntu/k8s/llm-deployment/control/config/k8s/base/metallb/metallb-ip-pool.yaml"

# 用于生成 VIP 的主网卡
IFACE="eno1"

# 公网转发端口（按需改）
PORTS="80,443"

# 如果你想 NAT 到某个 LoadBalancer Service 的 EXTERNAL-IP（可选）
# 不设置则默认 NAT 到生成的 VIRTUAL_IP
LB_SVC_NAMESPACE="${LB_SVC_NAMESPACE:-}"
LB_SVC_NAME="${LB_SVC_NAME:-}"

# 等待/超时参数
WAIT_NODE_READY_SEC=180
WAIT_METALLB_READY_SEC=240
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

get_public_ip() {
  curl -s --max-time 5 ifconfig.me || true
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
  log ">>> HARD RESET: 清理 Kubernetes/网络/证书/kubeconfig（每次运行都重来）"

  # 先尽力清掉 metallb（如果 kubeconfig 还能用）
  (kubectl delete ipaddresspools.metallb.io --all -A --ignore-not-found 2>/dev/null || true) || true
  (kubectl delete l2advertisements.metallb.io --all -A --ignore-not-found 2>/dev/null || true) || true
  (kubectl delete ns metallb-system --ignore-not-found 2>/dev/null || true) || true

  # kubeadm reset
  kubeadm reset -f || true

  # 彻底清理控制面/etcd
  rm -rf /etc/kubernetes /var/lib/etcd || true

  # CNI 配置
  rm -rf /etc/cni/net.d || true

  # kubeconfig（关键：避免旧证书导致 x509 unknown authority）
  rm -rf /root/.kube || true
  rm -rf /home/*/.kube || true

  # （可选）清一些常见残留目录
  rm -rf /var/lib/cni /var/lib/calico /var/run/calico || true

  log ">>> HARD RESET 完成"
}

# =========================
# kubeadm init + kubeconfig
# =========================
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
# MetalLB
# =========================
install_metallb() {
  log ">>> 安装 MetalLB"
  kubectl apply -f "${METALLB_MANIFEST_URL}"
}

wait_for_metallb_ready() {
  log ">>> 等待 MetalLB Controller / Speaker Ready"
  kubectl rollout status -n metallb-system deploy/controller --timeout="${WAIT_METALLB_READY_SEC}s"
  kubectl rollout status -n metallb-system ds/speaker --timeout="${WAIT_METALLB_READY_SEC}s"
  kubectl get pods -n metallb-system -o wide || true
}

# =========================
# VIP generation (IMPORTANT: logs -> stderr, value -> stdout)
# =========================
generate_virtual_ip() {
  echo ">>> Detect node IP from interface: ${IFACE}" >&2

  local node_ip prefix candidate
  node_ip=$(ip -4 addr show dev "$IFACE" | awk '/inet /{print $2}' | cut -d/ -f1)
  [[ -z "$node_ip" ]] && { echo "❌ Failed to detect node IP on ${IFACE}" >&2; return 1; }

  echo "✔ Node IP: ${node_ip}" >&2
  prefix=$(echo "$node_ip" | cut -d. -f1-3)
  echo "✔ IP prefix: ${prefix}.x" >&2
  echo ">>> Searching free virtual IP in ${prefix}.200–250" >&2

  for i in $(seq 200 250); do
    candidate="${prefix}.${i}"
    [[ "$candidate" == "$node_ip" ]] && continue
    if ! ping -c1 -W1 "$candidate" &>/dev/null; then
      echo "$candidate"
      return 0
    fi
  done

  echo "❌ No free virtual IP found" >&2
  return 1
}

apply_metallb_ip_pool() {
  local vip="$1"
  [[ -f "${METALLB_CONFIG}" ]] || die "找不到 METALLB_CONFIG: ${METALLB_CONFIG}"

  log ">>> patch MetalLB IP pool: VIRTUAL_IP -> ${vip}"
  sed -i "s|VIRTUAL_IP|${vip}|g" "${METALLB_CONFIG}"

  log ">>> apply MetalLB IP pool"
  kubectl apply -f "${METALLB_CONFIG}"
}

# =========================
# NAT
# =========================
get_svc_external_ip_optional() {
  local ns="$1" name="$2"
  [[ -z "$ns" || -z "$name" ]] && return 0
  kubectl get svc "$name" -n "$ns" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true
}

setup_nat() {
  local public_ip="$1"
  local target_ip="$2"
  [[ -n "$public_ip" ]] || die "PUBLIC_IP 为空，无法配置 NAT"
  [[ -n "$target_ip" ]] || die "TARGET_IP 为空，无法配置 NAT"

  log ">>> 配置 NAT：${public_ip} -> ${target_ip} (ports: ${PORTS})"

  # ensure ip_forward
  sysctl -w net.ipv4.ip_forward=1 >/dev/null

  # idempotent cleanup
  iptables -t nat -D PREROUTING -d "$public_ip" -p tcp -m multiport --dports "$PORTS" \
    -j DNAT --to-destination "$target_ip" 2>/dev/null || true

  iptables -t nat -D POSTROUTING -d "$target_ip" -p tcp -m multiport --dports "$PORTS" \
    -j MASQUERADE 2>/dev/null || true

  # add rules
  iptables -t nat -A PREROUTING \
    -d "$public_ip" -p tcp -m multiport --dports "$PORTS" \
    -j DNAT --to-destination "$target_ip"

  iptables -t nat -A POSTROUTING \
    -d "$target_ip" -p tcp -m multiport --dports "$PORTS" \
    -j MASQUERADE

  log "✅ NAT 完成：PUBLIC_IP=${public_ip} -> TARGET_IP=${target_ip}"
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

# MetalLB
install_metallb
wait_for_metallb_ready

# VIP + pool
VIRTUAL_IP="$(generate_virtual_ip)"
log "✔ Selected MetalLB virtual IP: ${VIRTUAL_IP}"
apply_metallb_ip_pool "${VIRTUAL_IP}"

# NAT
PUBLIC_IP="$(get_public_ip)"
log ">>> 公网 IP: ${PUBLIC_IP:-<empty>}"
if [[ -z "$PUBLIC_IP" ]]; then
  log "⚠️  未获取到公网 IP（ifconfig.me），跳过 NAT 配置"
else
  TARGET_IP="$(get_svc_external_ip_optional "${LB_SVC_NAMESPACE}" "${LB_SVC_NAME}")"
  if [[ -n "$TARGET_IP" ]]; then
    log "✔ 使用 LoadBalancer Service EXTERNAL-IP 作为 NAT target: ${TARGET_IP} (ns=${LB_SVC_NAMESPACE}, svc=${LB_SVC_NAME})"
  else
    TARGET_IP="${VIRTUAL_IP}"
    log "✔ 未指定/未找到 LoadBalancer Service，使用 VIRTUAL_IP 作为 NAT target: ${TARGET_IP}"
  fi
  setup_nat "${PUBLIC_IP}" "${TARGET_IP}"
fi

print_join_cmd

log "===== 完成 ====="
log ">>> 检查：kubectl get nodes && kubectl get pods -A"
