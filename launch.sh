#!/bin/bash
set -e

# ======= 配置区域 =======
GITHUB_USERNAME="Johnny-dai-git"
GITHUB_TOKEN="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"
GITHUB_REPO="llm-deployment"
GITHUB_BRANCH="main"
GITHUB_URL="https://${GITHUB_TOKEN}@github.com/${GITHUB_USERNAME}/${GITHUB_REPO}.git"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}"
INSTALL_DIR="${REPO_DIR}/install"
CONTROL_DIR="${REPO_DIR}/control"

echo "===== 本地 system 节点完整初始化开始（control plane）====="

# ================================================================
# Phase 0: 确保 git 已安装
# ================================================================
echo "===== Phase 0: 确保 git 已安装 ====="
which git || (sudo apt update && sudo apt install -y git)

# ================================================================
# Phase 1: 更新 GitHub 仓库
# ================================================================
echo "===== Phase 1: 更新 GitHub 仓库 ====="
cd "${REPO_DIR}"
if [ -d ".git" ]; then
  git pull origin ${GITHUB_BRANCH} || echo "⚠ Git pull failed, continuing..."
fi

# ================================================================
# Phase 2: 通用初始化
# ================================================================
echo "===== Phase 2: 执行 all_install.sh ====="
cd "${INSTALL_DIR}"
sudo bash all_install.sh

# ================================================================
# Phase 3: 初始化 Kubernetes 控制平面
# ================================================================
echo "===== Phase 3: 执行 system.sh ====="
sudo bash system.sh

# ================================================================
# Phase 4: 集群基础设施 + GPU Bootstrap
# ================================================================
echo "===== Phase 4: 集群基础设施 + GPU Bootstrap ====="

# ------------------------------------------------
# Step 0: NVIDIA Device Plugin
# ------------------------------------------------
echo "===== Step 0: Install NVIDIA Device Plugin ====="

if [ -f "${CONTROL_DIR}/config/k8s/system/nvidia-device-plugin.yaml" ]; then
  kubectl apply -f "${CONTROL_DIR}/config/k8s/system/nvidia-device-plugin.yaml"
elif [ -f "${REPO_DIR}/script/nvidia-device-plugin.yaml" ]; then
  kubectl apply -f "${REPO_DIR}/script/nvidia-device-plugin.yaml"
else
  echo "❌ nvidia-device-plugin.yaml not found"
  exit 1
fi

echo ">>> Waiting for NVIDIA device plugin to be ready..."
kubectl rollout status ds/nvidia-device-plugin-daemonset -n kube-system --timeout=60s || \
  echo "⚠ Device plugin rollout may still be in progress, continuing..."
sleep 2
kubectl describe node system | grep -A4 nvidia.com/gpu || \
  echo "⚠ GPU not visible yet, continue..."

# ------------------------------------------------
# Step 0.5: Ensure NVIDIA RuntimeClass (CRITICAL)
# ------------------------------------------------
echo "===== Step 0.5: Ensure NVIDIA RuntimeClass ====="

RUNTIMECLASS_YAML="${CONTROL_DIR}/config/k8s/system/runtimeclass-nvidia.yaml"

if [ -f "${RUNTIMECLASS_YAML}" ]; then
  kubectl get runtimeclass nvidia >/dev/null 2>&1 || \
    kubectl apply -f "${RUNTIMECLASS_YAML}"
  echo "✔ RuntimeClass nvidia created/verified from ${RUNTIMECLASS_YAML}"
else
  echo ">>> runtimeclass-nvidia.yaml not found, creating inline..."
  cat <<EOF | kubectl apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
EOF
fi

kubectl get runtimeclass nvidia
echo ">>> RuntimeClass nvidia details:"
kubectl get runtimeclass nvidia -o yaml | grep -A2 "handler:"

# ------------------------------------------------
# Step 1: Namespaces / Node labels
# ------------------------------------------------
cd "${CONTROL_DIR}"

kubectl apply -f config/k8s/base/namespaces/

SYSTEM_NODE="system"
kubectl label node ${SYSTEM_NODE} system=true ingress=true gpu-node=true --overwrite

# ------------------------------------------------
# Step 2: ingress-nginx
# ------------------------------------------------
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx || true
helm repo update

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.hostNetwork=true \
  --set controller.dnsPolicy=ClusterFirstWithHostNet \
  --set controller.service.type=ClusterIP

# ------------------------------------------------
# Step 3: ArgoCD
# ------------------------------------------------
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
sleep 15
kubectl apply -f config/k8s/argocd/argocd-ingress.yaml

kubectl apply -f config/k8s/argocd/base-application.yaml
kubectl apply -f config/k8s/argocd/llm-application.yaml
kubectl apply -f config/k8s/argocd/monitoring-application.yaml
kubectl apply -f config/k8s/argocd/argocd-ingress-application.yaml

# ------------------------------------------------
# Step 3.5: ArgoCD Image Updater
# ------------------------------------------------
echo "===== Step 3.5: Install ArgoCD Image Updater ====="

# 创建必要的 Secret（Git 写回凭证和 Docker Registry 认证）
echo ">>> Creating Image Updater secrets..."
kubectl apply -f config/k8s/argocd/image-updater/git-credentials-secret.yaml
kubectl apply -f config/k8s/argocd/image-updater/docker-registry-secret.yaml

# 安装 ArgoCD Image Updater（使用 Helm）
echo ">>> Installing ArgoCD Image Updater via Helm..."
helm repo add argo https://argoproj.github.io/argo-helm || true
helm repo update

helm upgrade --install argocd-image-updater argo/argocd-image-updater \
  --namespace argocd \
  --create-namespace \
  -f config/k8s/argocd/image-updater/values.yaml \
  --wait --timeout=5m || echo "⚠ Image Updater installation may still be in progress..."

echo ">>> Waiting for Image Updater to be ready..."
sleep 10
kubectl get pods -n argocd | grep image-updater || echo "⚠ Image Updater pods may still be starting..."

# ------------------------------------------------
# Step 4: 状态检查
# ------------------------------------------------
kubectl get runtimeclass
kubectl get nodes -o wide
kubectl get pods -A -o wide

echo ""
echo "🎉 GPU-ready Kubernetes cluster bootstrap 完成"