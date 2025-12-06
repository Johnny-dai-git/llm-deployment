#!/bin/bash
set -e
echo "===== 通用初始化 (all_install.sh) ====="

##############################################
# 0. 检测是否为 GPU 节点（用于跳过某些步骤）
##############################################
IS_GPU_NODE=0
if lspci | grep -i nvidia >/dev/null 2>&1; then
    IS_GPU_NODE=1
    echo "⚠️ 检测到 NVIDIA GPU —— 将以 GPU 节点模式运行"
else
    echo "ℹ️ 未检测到 GPU —— 以 CPU 节点模式运行"
fi

##############################################
# 1. 禁用 swap（所有节点都需要）
##############################################
echo "[1/4] 禁用 swap"
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

##############################################
# 2. GPU 节点：清理所有冲突的 NVIDIA apt 源
##############################################
if [ "$IS_GPU_NODE" -eq 1 ]; then
    echo "[2/4] GPU 节点：清理 NVIDIA apt 源，避免 apt Signed-By 冲突"

    sudo rm -f /etc/apt/sources.list.d/nvidia-container-toolkit.list
    sudo rm -f /etc/apt/sources.list.d/nvidia-docker.list
    sudo rm -f /etc/apt/sources.list.d/libnvidia-container.list
    sudo rm -f /etc/apt/sources.list.d/nvidia*.list

    # 某些系统会放在 /etc/apt/sources.list
    sudo sed -i '/nvidia.github.io/d' /etc/apt/sources.list
else
    echo "[2/4] CPU 节点：无需清理 NVIDIA 源"
fi

##############################################
# 3. 添加 Kubernetes 仓库（所有节点都需要）
##############################################
echo "[3/4] 添加 Kubernetes 仓库 & 安装 kubeadm/kubelet/kubectl"

sudo mkdir -p /etc/apt/keyrings

# 安装 key，不会触发交互
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key \
    | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/k8s.gpg

# sources.list.d
echo "deb [signed-by=/etc/apt/keyrings/k8s.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" \
    | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

# 更新
sudo apt update -y

# 安装 k8s 组件
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

##############################################
# 4. CPU 节点才安装 containerd（GPU 节点跳过！）
##############################################
if [ "$IS_GPU_NODE" -eq 0 ]; then
    echo "[4/4] CPU 节点：安装 containerd"
    sudo apt install -y containerd

    echo "➡ 配置 systemd cgroup（K8s 推荐）"
    sudo mkdir -p /etc/containerd
    containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    sudo systemctl restart containerd
else
    echo "[4/4] GPU 节点：跳过 containerd 安装（我们使用 Docker + NVIDIA）"
fi

echo "===== all_install.sh 执行完毕 ====="

