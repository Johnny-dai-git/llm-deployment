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
echo "[1/5] 禁用 swap"
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

##############################################
# 2. GPU 节点：清理所有冲突的 NVIDIA apt 源
##############################################
if [ "$IS_GPU_NODE" -eq 1 ]; then
    echo "[2/5] GPU 节点：清理 NVIDIA apt 源，避免 apt Signed-By 冲突"

    sudo rm -f /etc/apt/sources.list.d/nvidia-container-toolkit.list
    sudo rm -f /etc/apt/sources.list.d/nvidia-docker.list
    sudo rm -f /etc/apt/sources.list.d/libnvidia-container.list
    sudo rm -f /etc/apt/sources.list.d/nvidia*.list

    # 某些系统会放在 /etc/apt/sources.list
    sudo sed -i '/nvidia.github.io/d' /etc/apt/sources.list
else
    echo "[2/5] CPU 节点：无需清理 NVIDIA 源"
fi

##############################################
# 3. 添加 Kubernetes 仓库（所有节点都需要）
##############################################
echo "[3/5] 添加 Kubernetes 仓库 & 安装 kubeadm/kubelet/kubectl"

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
    echo "[4/5] CPU 节点：安装 containerd"
    sudo apt install -y containerd

    echo "➡ 配置 systemd cgroup（K8s 推荐）"
    sudo mkdir -p /etc/containerd
    containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    sudo systemctl restart containerd
else
    echo "[4/5] GPU 节点：跳过 containerd 安装（我们使用 Docker + NVIDIA）"
fi

##############################################
# 5. 配置 Docker（所有节点都需要，用于 pull image）
##############################################
echo "[5/5] 配置 Docker（所有节点都需要，用于 pull image）"

# 检查 Docker 是否已安装
if ! command -v docker &> /dev/null; then
    echo "➡ Docker 未安装，正在安装 Docker..."
    sudo apt update -y
    sudo apt install -y docker.io
else
    echo "➡ Docker 已安装"
fi

# 启动 Docker 服务
echo "➡ 启动 Docker 服务"
sudo systemctl start docker
sudo systemctl enable docker

# 将当前用户添加到 docker 组（如果未添加）
CURRENT_USER=${SUDO_USER:-$USER}
if [ -z "$CURRENT_USER" ] || [ "$CURRENT_USER" = "root" ]; then
    CURRENT_USER=$(whoami)
fi

if ! groups "$CURRENT_USER" | grep -q docker; then
    echo "➡ 将用户 $CURRENT_USER 添加到 docker 组"
    sudo usermod -aG docker "$CURRENT_USER"
    echo "⚠️  用户已添加到 docker 组，但需要重新登录或运行 'newgrp docker' 才能生效"
    echo "   或者运行: newgrp docker"
else
    echo "➡ 用户 $CURRENT_USER 已在 docker 组中"
fi

# 验证 Docker 是否运行
if sudo systemctl is-active --quiet docker; then
    echo "✓ Docker 服务正在运行"
else
    echo "⚠️  Docker 服务未运行，请检查"
fi

echo "===== all_install.sh 执行完毕 ====="
