#!/bin/bash
set -e

# ======= 配置区域 =======
GITHUB_USERNAME="${GITHUB_USERNAME:-Johnny-dai-git}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_REPO="${GITHUB_REPO:-llm-deployment}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"

if [ -n "${GITHUB_TOKEN}" ]; then
  GITHUB_URL="https://${GITHUB_TOKEN}@github.com/${GITHUB_USERNAME}/${GITHUB_REPO}.git"
else
  GITHUB_URL="https://github.com/${GITHUB_USERNAME}/${GITHUB_REPO}.git"
  echo "⚠️  GITHUB_TOKEN not set, using git credential helper"
fi

STORAGE_DEVICE="/dev/sda4"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_DIR="${SCRIPT_DIR}"
CONTROL_DIR="${REPO_DIR}/tools"

echo "===== Kubernetes control-plane bootstrap start ====="

# ================================================================
# Phase 0: git
# ================================================================
which git || (sudo apt update && sudo apt install -y git)

# ================================================================
# Phase 1: update repo
# ================================================================
cd "${REPO_DIR}"
[ -d .git ] && git pull origin "${GITHUB_BRANCH}" || true

# ================================================================
# Phase 2: common install
# ================================================================
cd "${INSTALL_DIR}"
sudo bash all_install.sh

# ================================================================
# Phase 3: k8s init
# ================================================================
sudo bash system.sh

# ================================================================
# Phase 3.5: Label node
# ================================================================
echo ">>> Labeling node 'system' with system=true"
kubectl label node system system=true --overwrite || true

# 检测是否为 GPU 节点，如果是则添加 gpu-node=true 标签
if lspci | grep -i nvidia >/dev/null 2>&1; then
    echo ">>> GPU detected, labeling node 'system' with gpu-node=true"
    kubectl label node system gpu-node=true --overwrite || true
else
    echo ">>> No GPU detected, skipping gpu-node label"
fi

# ================================================================
# Phase 4: infra + GPU
# ================================================================
kubectl apply -f "${CONTROL_DIR}/system/nvidia-device-plugin.yaml" || true
kubectl rollout status ds/nvidia-device-plugin-daemonset -n kube-system --timeout=60s || true

# RuntimeClass
kubectl get runtimeclass nvidia >/dev/null 2>&1 || \
kubectl apply -f "${CONTROL_DIR}/system/runtimeclass-nvidia.yaml"

# ================================================================
# Storage (local-path)
# ================================================================
MOUNT_POINT=$(findmnt -n -o TARGET "${STORAGE_DEVICE}" || true)
[ -z "${MOUNT_POINT}" ] && MOUNT_POINT=$(lsblk -n -o MOUNTPOINT "${STORAGE_DEVICE}" | head -1)

LOCAL_STORAGE_PATH="${MOUNT_POINT}/k8s"
sudo mkdir -p "${LOCAL_STORAGE_PATH}"
sudo chmod 755 "${LOCAL_STORAGE_PATH}"

kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
sleep 10

kubectl patch configmap local-path-config -n local-path-storage --type merge -p \
"{\"data\":{\"config.json\":\"{\\\"nodePathMap\\\":[{\\\"node\\\":\\\"DEFAULT_PATH_FOR_NON_LISTED_NODES\\\",\\\"paths\\\":[\\\"${LOCAL_STORAGE_PATH}\\\"]}]}\"}}"

kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' || true

# ================================================================
# Helm repos
# ================================================================
helm repo add argo https://argoproj.github.io/argo-helm || true
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
helm repo add nvidia https://nvidia.github.io/dcgm-exporter/helm-charts || true
helm repo update

# ================================================================
# ingress-nginx
# ================================================================
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace \
  --set controller.hostNetwork=true \
  --set controller.dnsPolicy=ClusterFirstWithHostNet \
  --set controller.service.type=ClusterIP

kubectl rollout status deployment ingress-nginx-controller -n ingress-nginx --timeout=120s || true

# ================================================================
# ArgoCD
# ================================================================
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install argocd argo/argo-cd \
  -n argocd \
  -f "${CONTROL_DIR}/helm/argocd/values.yaml" \
  --wait --timeout 10m

# ================================================================
# ArgoCD Image Updater (手写 YAML 管理)
# ================================================================
echo "===== Installing ArgoCD Image Updater ====="

# 0️⃣ 确认 namespace
kubectl get ns argocd || kubectl create ns argocd

# 1️⃣ 创建 ServiceAccount（必须）
echo ">>> Step 1: Creating ServiceAccount..."
kubectl apply -f "${CONTROL_DIR}/argocd-image-updater/argocd-image-updater-sa.yaml"

# 确认 ServiceAccount
kubectl get sa -n argocd | grep argocd-image-updater || echo "⚠️  ServiceAccount not found"

# 2️⃣ 应用 RBAC (ClusterRole + Binding)
echo ">>> Step 2: Applying RBAC..."
kubectl apply -f "${CONTROL_DIR}/argocd-image-updater/argocd-image-updater-clusterrole.yaml"
kubectl apply -f "${CONTROL_DIR}/argocd-image-updater/argocd-image-updater-clusterrolebinding.yaml"

# 立刻验证权限（关键一步）
echo ">>> Verifying RBAC permissions..."
if kubectl auth can-i list applications.argoproj.io \
  --as system:serviceaccount:argocd:argocd-image-updater 2>/dev/null | grep -q "yes"; then
  echo "✅ RBAC permissions verified"
else
  echo "⚠️  RBAC permissions check failed, but continuing..."
fi

# 3️⃣ 创建 ConfigMap（Image Updater 核心配置）
echo ">>> Step 3: Creating ConfigMap..."
kubectl apply -f "${CONTROL_DIR}/argocd-image-updater/argocd-image-updater-config.yaml"

# 确认 ConfigMap
kubectl get cm -n argocd | grep image-updater || echo "⚠️  ConfigMap not found"

# 4️⃣ 创建 ServiceAccount Token（K8s ≥1.24 推荐）
echo ">>> Step 4: Creating ServiceAccount Token..."
kubectl apply -f "${CONTROL_DIR}/argocd-image-updater/argocd-image-updater-token.yaml" || true

# 5️⃣ 启动 Image Updater Deployment
echo ">>> Step 5: Starting Image Updater Deployment..."
kubectl apply -f "${CONTROL_DIR}/argocd-image-updater/argocd-image-updater-controller.yaml"

# 等待 Deployment 就绪
echo ">>> Waiting for Image Updater to be ready..."
kubectl rollout status deployment/argocd-image-updater-controller -n argocd --timeout=5m || echo "⚠️  Deployment may still be starting..."

# ================================================================
# ArgoCD Applications (Image Updater 需要这些 Application 才能工作)
# ================================================================
echo "===== Deploying ArgoCD Applications ====="

# 部署 LLM Platform Services Application
echo ">>> Deploying llm-platform-services Application..."
kubectl apply -f "${CONTROL_DIR}/argocd-image-updater/llm-application.yaml"

# 等待 Application 创建完成
echo ">>> Waiting for Application to be created..."
sleep 5
kubectl get application llm-platform-services -n argocd || echo "⚠️  Application not found"

echo "✅ ArgoCD Applications deployed"

# ================================================================
# Monitoring
# ================================================================
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f "${CONTROL_DIR}/helm/monitoring/kps-values.yaml" \
  --wait --timeout 10m

helm upgrade --install dcgm nvidia/dcgm-exporter \
  -n monitoring \
  -f "${CONTROL_DIR}/helm/monitoring/dcgm/values.yaml" \
  --wait --timeout 5m

# ================================================================
# Final check
# ================================================================
kubectl get pods -A
kubectl get nodes -o wide

echo "🎉 Kubernetes + ArgoCD + Image Updater bootstrap DONE"
