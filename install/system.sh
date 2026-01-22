#!/bin/bash
set -euo pipefail

# =========================
# Config
# =========================
NODE_NAME="system"
POD_CIDR="192.168.0.0/16"

CALICO_MANIFEST_URL="https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml"
METALLB_MANIFEST_URL="https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb-native.yaml"

# 你的 MetalLB pool 模板文件，里面必须包含占位符：VIRTUAL_IP
METALLB_CONFIG="/home/ubuntu/k8s/llm-deployment/control/config/k8s/base/metallb/metallb-ip-pool.yaml"

# 生成 VIP 时使用的网卡
IFACE="eno1"

# 需要对外暴露并做 NAT 的端口
PORTS="80,443"

# （可选）如果你已经有 LoadBalancer Service，希望脚本自动读取它的 EXTERNAL-IP 来做 NAT
# 没有的话就留空，脚本会直接用生成的 VIRTUAL_IP 做 NAT
LB_SVC_NAMESPACE="${LB_SVC_NAMESPACE:-}"
LB_SVC_NAME="${LB_SVC_NAME:-}"

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

  if grep -qE '^\s*SystemdCgroup\s*=\s*false\s*$' /etc/containerd/config.toml; then
    sed -i 's/^\(\s*SystemdCgroup\s*=\s*\)false\s*$/\1true/' /etc/containerd/config.toml
  else
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

  rm -rf /etc/cni/net.d || true
  rm -rf /root/.kube || true
}

ensure_deps() {
  log ">>> 安装依赖（net-tools / curl）"
  apt-get update -y
  apt-get install -y net-tools curl
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

install_metallb() {
  log ">>> 安装 MetalLB（native manifest）"
  kubectl apply -f "${METALLB_MANIFEST_URL}"
}

wait_for_metallb_ready() {
  log ">>> 等待 MetalLB Controller / Speaker Ready"
  kubectl rollout status -n metallb-system deploy/controller --timeout=180s || true
  # speaker 是 daemonset
  kubectl rollout status -n metallb-system ds/speaker --timeout=180s || true
  kubectl get pods -n metallb-system -o wide || true
}

generate_virtual_ip() {
  log ">>> Detect node IP from interface: ${IFACE}"
  local node_ip prefix virtual_ip candidate i

  node_ip=$(ip -4 addr show dev "$IFACE" | awk '/inet /{print $2}' | cut -d/ -f1)
  if [[ -z "$node_ip" ]]; then
    log "❌ Failed to detect node IP on ${IFACE}"
    return 1
  fi
  log "✔ Node IP: ${node_ip}"

  prefix=$(echo "$node_ip" | cut -d. -f1-3)
  log "✔ IP prefix: ${prefix}.x"
  log ">>> Searching free virtual IP in ${prefix}.200-250"

  virtual_ip=""
  for i in $(seq 200 250); do
    candidate="${prefix}.${i}"
    [[ "$candidate" == "$node_ip" ]] && continue
    if ! ping -c1 -W1 "$candidate" &>/dev/null; then
      virtual_ip="$candidate"
      break
    fi
  done

  if [[ -z "$virtual_ip" ]]; then
    log "❌ No free virtual IP found"
    return 1
  fi

  echo "$virtual_ip"
}

apply_metallb_ip_pool() {
  local vip="$1"
  if [[ ! -f "${METALLB_CONFIG}" ]]; then
    log "❌ ${METALLB_CONFIG} not found"
    exit 1
  fi

  log ">>> Replacing VIRTUAL_IP in ${METALLB_CONFIG} -> ${vip}"
  sed -i "s|VIRTUAL_IP|${vip}|g" "${METALLB_CONFIG}"

  log ">>> Apply MetalLB IP pool"
  kubectl apply -f "${METALLB_CONFIG}"
}

get_svc_external_ip_optional() {
  local ns="$1" name="$2"
  [[ -z "$ns" || -z "$name" ]] && return 0
  kubectl get svc "$name" -n "$ns" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true
}

setup_nat() {
  local public_ip="$1"
  local target_ip="$2"

  if [[ -z "$public_ip" || -z "$target_ip" ]]; then
    log "❌ setup_nat requires PUBLIC_IP and TARGET_IP"
    exit 1
  fi

  log ">>> Enable IPv4 forwarding"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null

  log ">>> Clean old NAT rules (if any)"
  iptables -t nat -D PREROUTING -d "$public_ip" -p tcp -m multiport --dports "$PORTS" \
    -j DNAT --to-destination "$target_ip" 2>/dev/null || true

  iptables -t nat -D POSTROUTING -d "$target_ip" -p tcp -m multiport --dports "$PORTS" \
    -j MASQUERADE 2>/dev/null || true

  log ">>> Add DNAT: ${public_ip} -> ${target_ip}"
  iptables -t nat -A PREROUTING \
    -d "$public_ip" -p tcp -m multiport --dports "$PORTS" \
    -j DNAT --to-destination "$target_ip"

  log ">>> Add SNAT (MASQUERADE)"
  iptables -t nat -A POSTROUTING \
    -d "$target_ip" -p tcp -m multiport --dports "$PORTS" \
    -j MASQUERADE

  log "✅ NAT configured"
  log "    PUBLIC_IP  -> ${public_ip}"
  log "    TARGET_IP  -> ${target_ip}"
}

# =========================
# Main
# =========================
need_root

log "===== system 节点稳态初始化开始（可反复运行）====="

ensure_deps
ensure_sysctl
disable_swap
ensure_containerd_systemd_cgroup
clean_kubeadm_state

MASTER_IP="$(get_master_ip)"
log ">>> 使用主节点 IP: ${MASTER_IP}"

kubeadm_init "${MASTER_IP}"
setup_kubeconfig_root

# CNI
install_calico
wait_for_cni_file
kick_cri_and_kubelet
wait_for_cri_network_ready
wait_for_node_ready || true

remove_controlplane_taint_for_single_node

# MetalLB
install_metallb
wait_for_metallb_ready

# MetalLB VIP + Pool
VIRTUAL_IP="$(generate_virtual_ip)"
log "✔ Selected MetalLB virtual IP: ${VIRTUAL_IP}"
apply_metallb_ip_pool "${VIRTUAL_IP}"

# NAT: PUBLIC -> (Service EXTERNAL-IP if exists) else -> VIRTUAL_IP
PUBLIC_IP="$(get_public_ip)"
log ">>> 公网 IP: ${PUBLIC_IP:-<empty>}"
if [[ -z "$PUBLIC_IP" ]]; then
  log "⚠️  未获取到公网 IP（ifconfig.me），跳过 NAT 配置"
else
  TARGET_IP="$(get_svc_external_ip_optional "${LB_SVC_NAMESPACE}" "${LB_SVC_NAME}")"
  if [[ -n "$TARGET_IP" ]]; then
    log "✔ Found LoadBalancer Service EXTERNAL-IP: ${TARGET_IP} (ns=${LB_SVC_NAMESPACE}, svc=${LB_SVC_NAME})"
  else
    TARGET_IP="${VIRTUAL_IP}"
    log "✔ No LoadBalancer Service specified/found, use VIRTUAL_IP as NAT target: ${TARGET_IP}"
  fi
  setup_nat "${PUBLIC_IP}" "${TARGET_IP}"
fi

print_join_cmd

CURRENT_USER="$(detect_current_user)"
setup_kubeconfig_user "${CURRENT_USER}"

log "===== system 节点稳态初始化完成 ====="
log ">>> 快速检查：kubectl get nodes && kubectl get pods -A"
