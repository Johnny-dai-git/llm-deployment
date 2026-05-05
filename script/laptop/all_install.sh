#!/bin/bash
set -e
echo "===== Common initialization (all_install.sh) ====="

##############################################
# 0. Detect if this is a GPU node (to skip certain steps)
##############################################
IS_GPU_NODE=0
if lspci | grep -i nvidia >/dev/null 2>&1; then
    IS_GPU_NODE=1
    echo "⚠️ Detected NVIDIA GPU — running in GPU node mode"
else
    echo "ℹ️ No GPU detected — running in CPU node mode"
fi

##############################################
# 1. Disable swap (required on all nodes)
##############################################
echo "[1/6] Disable swap"
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

##############################################
# 2. GPU node: clean all conflicting NVIDIA apt sources
##############################################
if [ "$IS_GPU_NODE" -eq 1 ]; then
    echo "[2/6] GPU node: clean NVIDIA apt sources, avoid apt Signed-By conflicts"

    sudo rm -f /etc/apt/sources.list.d/nvidia-container-toolkit.list
    sudo rm -f /etc/apt/sources.list.d/nvidia-docker.list
    sudo rm -f /etc/apt/sources.list.d/libnvidia-container.list
    sudo rm -f /etc/apt/sources.list.d/nvidia*.list

    # Some systems have it in /etc/apt/sources.list
    sudo sed -i '/nvidia.github.io/d' /etc/apt/sources.list
else
    echo "[2/6] CPU node: no need to clean NVIDIA sources"
fi

##############################################
# 2.5 GPU node: install nvidia-container-toolkit
# ----------------------------------------------------------------
# Required. Without this package, nvidia-ctk / nvidia-container-runtime
# binaries are missing, `nvidia-ctk runtime configure` in launch.sh
# Phase 2.5 will skip, containerd won't know how to run RuntimeClass
# 'nvidia', and any pod with runtimeClassName: nvidia (vllm-worker /
# dcgm-exporter) will hang at ContainerCreating with "no runtime for
# 'nvidia' is configured".
#
# Note: nvidia-device-plugin (k8s DaemonSet) ≠ nvidia-container-toolkit
# (host package), both required, cannot omit either.
##############################################
if [ "$IS_GPU_NODE" -eq 1 ]; then
    echo "[2.5/6] GPU node: install nvidia-container-toolkit"
    if ! command -v nvidia-ctk >/dev/null 2>&1; then
        # Add official repo (signed-by doesn't conflict with old sources cleaned above)
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
            sudo gpg --batch --yes --dearmor \
                -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

        curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
            sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
            sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

        sudo apt-get update -y
        sudo apt-get install -y nvidia-container-toolkit
        echo "  ✓ nvidia-container-toolkit installed: $(nvidia-ctk --version 2>/dev/null | head -1)"
    else
        echo "  ➡ nvidia-ctk already exists, skip installation"
    fi
fi

##############################################
# 3. Add Kubernetes repository (required on all nodes)
##############################################
echo "[3/6] Add Kubernetes repository & install kubeadm/kubelet/kubectl"

sudo mkdir -p /etc/apt/keyrings

# Install key, non-interactive
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key \
    | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/k8s.gpg

# sources.list.d
echo "deb [signed-by=/etc/apt/keyrings/k8s.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" \
    | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

# Update
sudo apt update -y

# Install k8s components
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

##############################################
# 4. Install on all nodes + enable containerd + write base config
# ----------------------------------------------------------------
# Important note: k8s 1.24+ removed dockershim, container runtime
# must be containerd (or other CRI-compatible) on both CPU and GPU
# nodes. In earlier versions, stop+disable containerd on GPU nodes
# was wrong and caused the cluster to fail after system reboot.
#
# Only write minimum required config: SystemdCgroup=true here.
# nvidia runtime is injected by launch.sh Phase 2.5 using
# `nvidia-ctk runtime configure` (only GPU nodes need it, depends on
# step 2.5 installing nvidia-ctk).
##############################################
echo "[4/6] Install and enable containerd, write base config (SystemdCgroup=true)"
if ! command -v containerd &> /dev/null; then
    echo "➡ Install containerd"
    sudo apt install -y containerd
else
    echo "➡ containerd already installed, skip installation"
fi

# If previous script version disabled containerd, force enable it here
echo "➡ Enable containerd service (auto-start on boot)"
sudo systemctl enable containerd

echo "➡ Write containerd config (systemd cgroup driver, K8s recommended)"
sudo mkdir -p /etc/containerd
# Regenerate config only if missing or SystemdCgroup is not true,
# to avoid overwriting nvidia runtime injected by launch.sh Phase 2.5
if [ ! -f /etc/containerd/config.toml ] || ! grep -q "SystemdCgroup = true" /etc/containerd/config.toml 2>/dev/null; then
    containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    sudo systemctl restart containerd
    echo "  ✓ Wrote SystemdCgroup=true and restarted containerd"
else
    echo "  ✓ /etc/containerd/config.toml already has SystemdCgroup=true, keep as is"
fi

##############################################
# 5. Configure Docker (for local build / pull image, optional)
# ----------------------------------------------------------------
# Note: k8s container runtime is containerd (see step 4), not Docker.
# Docker is installed here mainly for:
#   - local build-and-push.sh image building
#   - compatibility with some legacy dev workflows
# If you don't need these, this step can be completely removed.
##############################################
echo "[5/6] Configure Docker (for local build / pull image, optional)"

# Check if Docker is already installed
if ! command -v docker &> /dev/null; then
    echo "➡ Docker not installed, installing Docker..."
    sudo apt update -y
    sudo apt install -y docker.io
else
    echo "➡ Docker already installed"
fi

# Start Docker service
echo "➡ Start Docker service"
sudo systemctl start docker
sudo systemctl enable docker

# Add current user to docker group (if not already added)
CURRENT_USER=${SUDO_USER:-$USER}
if [ -z "$CURRENT_USER" ] || [ "$CURRENT_USER" = "root" ]; then
    CURRENT_USER=$(whoami)
fi

if ! groups "$CURRENT_USER" | grep -q docker; then
    echo "➡ Add user $CURRENT_USER to docker group"
    sudo usermod -aG docker "$CURRENT_USER"
    echo "⚠️  User added to docker group, but need to login again or run 'newgrp docker' to take effect"
    echo "   or run: newgrp docker"
else
    echo "➡ User $CURRENT_USER already in docker group"
fi

# Verify Docker is running
if sudo systemctl is-active --quiet docker; then
    echo "✓ Docker service is running"
else
    echo "⚠️  Docker service is not running, please check"
fi

##############################################
# 6. Install Helm (required on all nodes, for ArgoCD Image Updater)
##############################################
echo "[6/6] Install Helm (all nodes)"
if ! command -v helm >/dev/null 2>&1; then
    echo "➡ Helm not installed, installing Helm..."

    # Method 1: use official install script (recommended, works on all distros)
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

    # Verify installation
    if command -v helm >/dev/null 2>&1; then
        echo "✓ Helm installation successful"
        helm version
    else
        echo "⚠️  Helm installation may have failed, please check"
    fi
else
    echo "➡ Helm already installed"
    helm version
fi

echo "===== all_install.sh completed ====="
