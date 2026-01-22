#!/bin/bash
set -e

echo "===== system 节点预处理开始 ====="

# 获取当前节点的公网 IP
echo ">>> 正在获取公网 IP 地址..."
SYSTEM_NODE_IP=$(curl -s ifconfig.me)

if [ -z "$SYSTEM_NODE_IP" ]; then
    echo "❌ 无法获取公网 IP 地址，请检查网络连接"
    exit 1
fi

echo ">>> 检测到 system node 公网 IP: $SYSTEM_NODE_IP"

# 修改 metallb-ip-pool.yaml，使用当前节点的公网 IP
METALLB_CONFIG="/home/ubuntu/k8s/llm-deployment/control/config/k8s/base/metallb/metallb-ip-pool.yaml"
if [ -f "$METALLB_CONFIG" ]; then
    echo ">>> 修改 metallb-ip-pool.yaml 使用 system node 公网 IP: $SYSTEM_NODE_IP ..."
    sed -i "s|PUBLIC_IP|${SYSTEM_NODE_IP}|g" "$METALLB_CONFIG"
    echo "✔ Modified metallb-ip-pool.yaml"
else
    echo "⚠️  未找到 $METALLB_CONFIG，跳过 IP 替换"
fi

# 这里你可以按需加一些内核参数，比如：
# sudo modprobe br_netfilter || true
# cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
# net.bridge.bridge-nf-call-iptables  = 1
# net.bridge.bridge-nf-call-ip6tables = 1
# net.ipv4.ip_forward                 = 1
# EOF
# sudo sysctl --system

echo "===== system 节点预处理完成 ====="

echo ""
echo "===== 初始化 Kubernetes 控制平面开始 ====="

# 安装 net-tools（如果需要）
sudo apt install -y net-tools || true

echo ">>> 检查并修复 containerd cgroup 配置"

sudo mkdir -p /etc/containerd

if ! grep -q "SystemdCgroup = true" /etc/containerd/config.toml 2>/dev/null; then
    echo ">>> 修复 SystemdCgroup = true"
    containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    sudo systemctl restart containerd
else
    echo ">>> containerd cgroup 已正确配置"
fi

# ===== 在 cgroup 修复后加 =====
echo ">>> 关闭 swap"
sudo swapoff -a || true
sudo sed -i '/ swap / s/^/#/' /etc/fstab || true

echo ">>> 清理旧 kubeadm 状态（如存在）"
sudo kubeadm reset -f || true
sudo rm -rf /etc/cni/net.d ~/.kube

# 获取主节点 IP
MASTER_IP=$(hostname -I | awk '{print $1}')

echo "使用主节点 IP: $MASTER_IP"

echo "[1/4] 初始化 Kubernetes 控制平面"
sudo kubeadm init --node-name=system --pod-network-cidr=192.168.0.0/16 --control-plane-endpoint=$MASTER_IP

echo "[2/4] 配置 kubectl（当前为 root 用户）"
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

echo "[3/4] 安装 Calico CNI"
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml

echo "[4/4] 显示 join 命令（给 worker 用，调试时能看见）"
sudo kubeadm token create --print-join-command

echo "===== 控制平面初始化完成 ====="

# 配置 exouser 的 kubectl
# 配置当前用户的 kubectl（平台无关）
CURRENT_USER=$(logname 2>/dev/null || echo $SUDO_USER || whoami)
USER_HOME=$(eval echo "~$CURRENT_USER")

echo ">>> 配置 kubectl 给用户: $CURRENT_USER ($USER_HOME)"

mkdir -p "$USER_HOME/.kube"
sudo cp /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
sudo chown "$CURRENT_USER:$CURRENT_USER" "$USER_HOME/.kube/config"

echo "===== system 节点完整初始化完成 ====="
