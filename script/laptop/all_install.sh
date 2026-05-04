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
echo "[1/6] 禁用 swap"
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

##############################################
# 2. GPU 节点：清理所有冲突的 NVIDIA apt 源
##############################################
if [ "$IS_GPU_NODE" -eq 1 ]; then
    echo "[2/6] GPU 节点：清理 NVIDIA apt 源，避免 apt Signed-By 冲突"

    sudo rm -f /etc/apt/sources.list.d/nvidia-container-toolkit.list
    sudo rm -f /etc/apt/sources.list.d/nvidia-docker.list
    sudo rm -f /etc/apt/sources.list.d/libnvidia-container.list
    sudo rm -f /etc/apt/sources.list.d/nvidia*.list

    # 某些系统会放在 /etc/apt/sources.list
    sudo sed -i '/nvidia.github.io/d' /etc/apt/sources.list
else
    echo "[2/6] CPU 节点：无需清理 NVIDIA 源"
fi

##############################################
# 2.5 GPU 节点：安装 nvidia-container-toolkit
# ----------------------------------------------------------------
# 必装。没有这个包就没有 nvidia-ctk / nvidia-container-runtime 二进制,
# launch.sh Phase 2.5 里的 `nvidia-ctk runtime configure` 会跳过,
# containerd 也就不知道 RuntimeClass 'nvidia' 怎么跑,
# 任何 runtimeClassName: nvidia 的 pod (vllm-worker / dcgm-exporter)
# 都会卡在 ContainerCreating 报 "no runtime for 'nvidia' is configured"。
#
# 注意:nvidia-device-plugin (k8s DaemonSet) ≠ nvidia-container-toolkit
# (宿主机包),两个都要,缺一不可。
##############################################
if [ "$IS_GPU_NODE" -eq 1 ]; then
    echo "[2.5/6] GPU 节点：安装 nvidia-container-toolkit"
    if ! command -v nvidia-ctk >/dev/null 2>&1; then
        # 添加官方 repo (signed-by 与上一步清理过的旧源不冲突)
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
            sudo gpg --batch --yes --dearmor \
                -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

        curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
            sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
            sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

        sudo apt-get update -y
        sudo apt-get install -y nvidia-container-toolkit
        echo "  ✓ nvidia-container-toolkit 已安装: $(nvidia-ctk --version 2>/dev/null | head -1)"
    else
        echo "  ➡ nvidia-ctk 已存在,跳过安装"
    fi
fi

##############################################
# 3. 添加 Kubernetes 仓库（所有节点都需要）
##############################################
echo "[3/6] 添加 Kubernetes 仓库 & 安装 kubeadm/kubelet/kubectl"

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
# 4. 所有节点都装 + enable containerd + 写基础配置
# ----------------------------------------------------------------
# 重要修正:k8s 1.24+ 已经移除 dockershim,无论 CPU 还是 GPU 节点,
# 容器运行时都必须是 containerd(或其它 CRI 兼容运行时)。
# 之前的版本在 GPU 节点上 stop+disable containerd 是错的,会导致
# 系统重启后集群起不来。
#
# 这里只写 SystemdCgroup=true 这个最小必需配置,nvidia runtime 由
# launch.sh 的 Phase 2.5 在此之后用 `nvidia-ctk runtime configure`
# 注入(因为只有 GPU 节点需要,且依赖 step 2.5 装的 nvidia-ctk)。
##############################################
echo "[4/6] 安装并启用 containerd,写入基础配置(SystemdCgroup=true)"
if ! command -v containerd &> /dev/null; then
    echo "➡ 安装 containerd"
    sudo apt install -y containerd
else
    echo "➡ containerd 已安装,跳过安装步骤"
fi

# 如果之前的脚本版本 disable 过 containerd,这里强制 enable 回来
echo "➡ 启用 containerd 服务(开机自启)"
sudo systemctl enable containerd

echo "➡ 写入 containerd 配置(systemd cgroup driver,K8s 推荐)"
sudo mkdir -p /etc/containerd
# 只在配置缺失或 SystemdCgroup 不是 true 时重新生成,
# 避免覆盖 launch.sh Phase 2.5 注入的 nvidia runtime
if [ ! -f /etc/containerd/config.toml ] || ! grep -q "SystemdCgroup = true" /etc/containerd/config.toml 2>/dev/null; then
    containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    sudo systemctl restart containerd
    echo "  ✓ 已写入 SystemdCgroup=true 并重启 containerd"
else
    echo "  ✓ /etc/containerd/config.toml 已是 SystemdCgroup=true,保留"
fi

##############################################
# 5. 配置 Docker（用于本地 build / pull image,可选)
# ----------------------------------------------------------------
# 注意:k8s 自身的容器运行时是 containerd(见 step 4),不是 Docker。
# 这里装 Docker 主要是为了:
#   - 本地 build-and-push.sh 构建 image
#   - 兼容某些旧的开发流程
# 如果你不需要这些用例,这步可以整个删掉。
##############################################
echo "[5/6] 配置 Docker（用于本地 build / pull image,可选)"

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

##############################################
# 6. 安装 Helm（所有节点都需要，用于 ArgoCD Image Updater）
##############################################
echo "[6/6] 安装 Helm（所有节点）"
if ! command -v helm >/dev/null 2>&1; then
    echo "➡ Helm 未安装，正在安装 Helm..."
    
    # 方法1：使用官方安装脚本（推荐，适用于所有发行版）
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    
    # 验证安装
    if command -v helm >/dev/null 2>&1; then
        echo "✓ Helm 安装成功"
        helm version
    else
        echo "⚠️  Helm 安装可能失败，请检查"
    fi
else
    echo "➡ Helm 已安装"
    helm version
fi

echo "===== all_install.sh 执行完毕 ====="
