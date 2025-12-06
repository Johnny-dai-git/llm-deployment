#!/bin/bash
set -e

########################################
# 1. 基本配置：用户名 + 各个节点 IP
########################################

REMOTE_USER="exouser"

CONTROL_IP="149.165.150.232"       # control 节点

SYSTEM_NODES=(                  # system / CPU 节点
  "149.165.147.30"
)

GPU_NODES=(                     # GPU worker 节点
  "149.165.147.25" 
  "149.165.147.81"
)

ALL_NODES=("$CONTROL_IP" "${SYSTEM_NODES[@]}" "${GPU_NODES[@]}")

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

echo "[*] kubeadm reset -f ..."
sudo kubeadm reset -f || true

echo "[*] 停止 kubelet（如果在跑）..."
sudo systemctl stop kubelet || true

echo "[*] 删除 /etc/kubernetes /var/lib/etcd ..."
sudo rm -rf /etc/kubernetes /var/lib/etcd

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

