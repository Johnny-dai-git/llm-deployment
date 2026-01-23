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

# 应用 ArgoCD Applications（从新的 argocd-apps 目录）
kubectl apply -f config/k8s/argocd-apps/base-application.yaml
kubectl apply -f config/k8s/argocd-apps/llm-application.yaml
kubectl apply -f config/k8s/argocd-apps/monitoring-application.yaml
kubectl apply -f config/k8s/argocd/argocd-ingress-application.yaml

# ------------------------------------------------
# Step 3.4: 更新 Git Credentials Secret（从本地 key 文件）
# ------------------------------------------------
echo "===== Step 3.4: Update Git Credentials from local key file ====="

KEY_FILE="/home/ubuntu/k8s/keys/key"
GIT_CREDENTIALS_FILE="${CONTROL_DIR}/config/k8s/argocd-image-updater/image-updater/git-credentials-secret.yaml"

if [ -f "${KEY_FILE}" ]; then
  echo ">>> Reading GitHub token from ${KEY_FILE}..."
  # 从 key 文件中提取密码（格式：password: ghp_xxx）
  GITHUB_TOKEN=$(grep -E "^password:" "${KEY_FILE}" | sed 's/^password:[[:space:]]*//' | tr -d '\n\r')
  
  if [ -n "${GITHUB_TOKEN}" ]; then
    echo ">>> Updating git-credentials-secret.yaml with token..."
    # 替换 git-credentials-secret.yaml 中的占位符（匹配前面的空格和占位符）
    sed -i "s/\([[:space:]]*password:[[:space:]]*\)ghp_hpfxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx/\1${GITHUB_TOKEN}/" "${GIT_CREDENTIALS_FILE}"
    echo "✔ Git credentials updated successfully"
  else
    echo "⚠ Warning: Could not extract password from ${KEY_FILE}, using default placeholder"
  fi
else
  echo "⚠ Warning: Key file ${KEY_FILE} not found, using default placeholder in git-credentials-secret.yaml"
fi

# ------------------------------------------------
# Step 3.5: ArgoCD Image Updater
# ------------------------------------------------
echo "===== Step 3.5: Install ArgoCD Image Updater ====="

# 创建必要的 Secret（仅 Git 写回凭证）
# ⚠️ 重要：所有镜像都是 public 的，不需要 docker-registry-secret
# Image Updater 可以匿名访问 public registry 的 tag 列表
# 只需要 git-credentials 来写回 Git 仓库
# 注意：Image Updater 资源在 argocd-image-updater 目录（手动管理，不通过 ArgoCD）
echo ">>> Creating Image Updater secret (git-credentials only)..."
kubectl apply -f config/k8s/argocd-image-updater/image-updater/git-credentials-secret.yaml

# 安装 ArgoCD Image Updater（使用 YAML manifest）
# 先删除所有现有的 Image Updater Deployment（避免冲突）
echo ">>> Removing existing Image Updater Deployments to avoid conflict..."
kubectl delete deployment -n argocd argocd-image-updater argocd-image-updater-controller --ignore-not-found=true
sleep 3

# 安装基础资源（ConfigMap、ServiceAccount、RBAC 等）
echo ">>> Installing ArgoCD Image Updater base resources..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/v0.15.2/manifests/install.yaml || \
  echo "⚠ Official install.yaml may have failed, continuing with custom Deployment..."

# 再次删除官方 Deployment（install.yaml 会创建它，但我们使用自定义的）
echo ">>> Removing official Deployment (we use custom one)..."
kubectl delete deployment -n argocd argocd-image-updater --ignore-not-found=true
sleep 2

# 应用自定义的 Deployment（修复了 command/args 问题）
echo ">>> Applying custom ArgoCD Image Updater Deployment..."
kubectl apply -f config/k8s/system/argocd-image-updater-controller.yaml

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