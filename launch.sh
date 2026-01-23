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
CONTROL_DIR="${REPO_DIR}/tools"

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

if [ -f "${CONTROL_DIR}/system/nvidia-device-plugin.yaml" ]; then
  kubectl apply -f "${CONTROL_DIR}/system/nvidia-device-plugin.yaml"
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

RUNTIMECLASS_YAML="${CONTROL_DIR}/system/runtimeclass-nvidia.yaml"

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

kubectl apply -f base/namespaces/

SYSTEM_NODE="system"
kubectl label node ${SYSTEM_NODE} system=true ingress=true gpu-node=true --overwrite


# ------------------------------------------------
# Step 1.5: 添加 Helm 仓库
# ------------------------------------------------
echo "===== Step 1.5: 添加 Helm 仓库 ====="
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
helm repo add nvidia https://nvidia.github.io/dcgm-exporter/helm-charts || true
helm repo update
# ------------------------------------------------
# Step 2: ingress-nginx
# ------------------------------------------------
# 统一配置：所有情况都使用 hostNetwork: true
echo ">>> 配置 ingress-nginx：使用 hostNetwork（统一配置）"

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx || true
helm repo update

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx  \
  --namespace ingress-nginx  \
  --create-namespace  \
  --set controller.hostNetwork=true  \
  --set controller.dnsPolicy=ClusterFirstWithHostNet  \
  --set controller.service.type=ClusterIP

# 等待 ingress-nginx 完全就绪（生产级做法）
# ⚠️ 重要：必须等待 admission webhook Ready 才能创建 Ingress 资源
# 否则 Ingress 创建会失败（webhook 未就绪，无法验证 Ingress 资源）
echo ">>> Waiting for ingress-nginx controller to be ready..."
kubectl rollout status deployment ingress-nginx-controller \
  -n ingress-nginx --timeout=120s || echo "⚠ Controller rollout may still be in progress..."

# 等待 admission webhook configuration（正确方式）
# ⚠️ 注意：admission webhook 是 ValidatingWebhookConfiguration，不是 Deployment
# Webhook = API Server 调用 Service，需要等待 WebhookConfiguration 出现
echo ">>> Waiting for ingress-nginx admission webhook configuration..."
until kubectl get validatingwebhookconfiguration ingress-nginx-admission >/dev/null 2>&1; do
  echo "  Waiting for webhook configuration..."
  sleep 2
done
echo "✔ Admission webhook configuration ready"

# ------------------------------------------------
# Step 3: ArgoCD
# ------------------------------------------------
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
sleep 15
kubectl apply -f argocd/argocd-ingress.yaml

# 注意：Grafana / Prometheus / ArgoCD 已使用 Ingress + 子路径架构
# 所有服务的 root_url 都使用 %(protocol)s://%(domain)s/<path>/ 模式
# 不需要动态获取或替换 IP 地址


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
kubectl apply -f system/argocd-image-updater-controller.yaml

echo ">>> Waiting for Image Updater to be ready..."
sleep 10
kubectl get pods -n argocd | grep image-updater || echo "⚠ Image Updater pods may still be starting..."

# ------------------------------------------------
# Step 3.6: 安装 Monitoring Stack (Helm)
# ------------------------------------------------
echo "===== Step 3.6: Install Monitoring Stack (Helm) ====="

# 确保 Helm repo 已添加（Step 1.5 已添加，这里再次确认）
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
helm repo add nvidia https://nvidia.github.io/dcgm-exporter/helm-charts || true
helm repo update

# 安装 kube-prometheus-stack (Grafana + Prometheus)
echo ">>> Installing kube-prometheus-stack..."
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring \
  --create-namespace \
  -f "${REPO_DIR}/helm/monitoring/kps-values.yaml" \
  --wait --timeout 10m || \
  echo "⚠ kube-prometheus-stack installation may still be in progress..."

# 安装 DCGM exporter (GPU metrics)
echo ">>> Installing dcgm-exporter..."
helm upgrade --install dcgm nvidia/dcgm-exporter \
  -n monitoring \
  -f "${REPO_DIR}/helm/monitoring/dcgm/values.yaml" \
  --wait --timeout 5m || \
  echo "⚠ dcgm-exporter installation may still be in progress..."

echo ">>> Checking monitoring pods..."
kubectl get pods -n monitoring || echo "⚠ Monitoring pods may still be starting..."

# ------------------------------------------------
# Step 4: 状态检查
# ------------------------------------------------
kubectl get runtimeclass
kubectl get nodes -o wide
kubectl get pods -A -o wide

echo ""
echo "🎉 GPU-ready Kubernetes cluster bootstrap 完成"