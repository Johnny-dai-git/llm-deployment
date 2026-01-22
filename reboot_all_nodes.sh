#!/bin/bash
set -e

########################################
# 1. 基本配置：用户名 + 各个节点 IP
########################################

REMOTE_USER="exouser"

# CONTROL_IP="149.165.150.232"       # control 节点
# CONTROL_IP removed - system node now serves as control plane

SYSTEM_NODES=(                  # system / CPU 节点
  "149.165.147.30"
)

GPU_NODES=(                     # GPU worker 节点
  "149.165.147.25" 
  "149.165.147.81"
)

ALL_NODES=("${SYSTEM_NODES[@]}" "${GPU_NODES[@]}")  # Removed CONTROL_IP - system node is control plane

########################################
# 2. 提示一下，防止误操作
########################################

echo "⚠️  即将在以下节点上执行：kubeadm reset + 清理 /etc/kubernetes /var/lib/etcd + reboot"
for IP in "${ALL_NODES[@]}"; do
  echo "   - ${IP}"
done
echo
echo "按 Ctrl+C 取消，或等待 5 秒继续..."
sleep 5

########################################
# 3. 先在所有节点上做 kubeadm reset + 清理残留
########################################

for IP in "${ALL_NODES[@]}"; do
  echo
  echo ">>> [$IP] 执行 kubeadm reset + 清理 K8s 目录 ..."
  ssh "${REMOTE_USER}@${IP}" "bash -s" << 'EOF'
set -e

echo "[*] 1. 停止所有相关服务..."
sudo systemctl stop kubelet 2>/dev/null || echo "  kubelet 未运行或已停止"
sudo systemctl stop containerd 2>/dev/null || echo "  containerd 未运行或已停止"
sudo systemctl stop docker 2>/dev/null || echo "  docker 未运行或已停止"

echo "[*] 2. 重新加载 systemd 以释放 cgroup..."
sudo systemctl daemon-reexec 2>/dev/null || echo "  daemon-reexec 执行完成"

echo "[*] 3. 等待服务完全停止..."
sleep 2

echo "[*] 4. 执行 kubeadm reset..."
sudo kubeadm reset -f || {
  echo "  ⚠️  kubeadm reset 遇到错误，继续清理..."
}

echo "[*] 5. 删除 /etc/kubernetes /var/lib/etcd ..."
sudo rm -rf /etc/kubernetes /var/lib/etcd

echo "[*] 6. 清理 CNI 配置..."
sudo rm -rf /etc/cni/net.d /var/lib/cni /var/lib/calico /var/run/calico

echo "[*] 清理完成。"
EOF
done

########################################
# 4. 依次 reboot 所有节点
########################################

for IP in "${ALL_NODES[@]}"; do
  echo
  echo ">>> [$IP] 执行 reboot ..."
  # reboot 之后 SSH 会立刻断开，所以加 || true 防止脚本退出
  ssh "${REMOTE_USER}@${IP}" "sudo reboot" || true
done

echo
echo "✅ 所有节点已执行 reset + reboot。"
echo "✨ 等几分钟机器起来之后，你就可以重新跑：./run_all.sh 重新初始化集群。"

