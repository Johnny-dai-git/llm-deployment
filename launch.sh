#!/bin/bash
set -e

# ======= 配置区域 =======
# GitHub repository configuration
GITHUB_USERNAME="Johnny-dai-git"
GITHUB_TOKEN="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"
GITHUB_REPO="llm-deployment"
GITHUB_BRANCH="main"
GITHUB_URL="https://${GITHUB_TOKEN}@github.com/${GITHUB_USERNAME}/${GITHUB_REPO}.git"

# 获取脚本所在目录
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
# Phase 1: 更新或克隆 GitHub 仓库
# ================================================================
echo
echo "===== Phase 1: 更新或克隆 GitHub 仓库 ====="

cd "${REPO_DIR}"
if [ -d ".git" ]; then
  echo ">>> 仓库已存在，拉取最新更改..."
  git pull origin ${GITHUB_BRANCH} || echo "⚠ Git pull failed, continuing..."
else
  echo ">>> 当前目录不是 git 仓库，跳过 pull"
fi

# ================================================================
# Phase 2: 执行 all_install.sh（通用初始化）
# ================================================================
echo
echo "===== Phase 2: 执行 all_install.sh（通用初始化）====="
echo ">>> 在本地执行 all_install.sh ..."
cd "${INSTALL_DIR}"
sudo bash all_install.sh

# ================================================================
# Phase 3: 执行 system.sh（包含 control.sh 的内容）
# ================================================================
echo
echo "===== Phase 3: 执行 system.sh（初始化 Kubernetes 控制平面）====="
echo ">>> 在本地执行 system.sh ..."
cd "${INSTALL_DIR}"
sudo bash system.sh




# ================================================================
# Phase 4: 部署基础设施（原 run_control 的内容）
# ================================================================
echo
echo "===== Phase 4: 部署基础设施（ingress-nginx, ArgoCD）====="

# 切换到 control 目录（因为 run_control 的路径是相对于 control 目录的）
cd "${CONTROL_DIR}"

echo "================ Step 1: Apply namespaces ================"
kubectl apply -f config/k8s/base/namespaces/

echo "================ Step 2: Label nodes ====================="
SYSTEM_NODE="system"
echo "Labeling system node..."
kubectl label node $SYSTEM_NODE system=true ingress=true --overwrite

echo "================ Step 3: Deploy ingress-nginx (Helm) ============"
# Step 3.1: Check Helm installation
echo ">>> Checking Helm installation..."
if ! command -v helm >/dev/null 2>&1; then
    echo "❌ Helm not found. Please install helm before installing ingress-nginx."
    echo "   Run: curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
    exit 1
fi
echo "✔ Helm is installed: $(helm version --short)"

# Step 3.2: Add ingress-nginx Helm repository
echo ">>> Adding ingress-nginx Helm repository..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || echo "⚠ Helm repo may already exist"
helm repo update

# Step 3.3: Install ingress-nginx using Helm with hostNetwork mode
echo ">>> Installing ingress-nginx using Helm (hostNetwork mode)..."
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.hostNetwork=true \
  --set controller.dnsPolicy=ClusterFirstWithHostNet \
  --set controller.service.type=ClusterIP

echo "✔ ingress-nginx installed via Helm (hostNetwork mode, listening on host ports 80/443)"

echo "================ Step 4: Deploy ArgoCD ==================="
# Step 4.1: Create ArgoCD namespace
echo ">>> Creating ArgoCD namespace..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Step 4.2: Install official ArgoCD
echo ">>> Installing official ArgoCD..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Step 4.3: Wait for ArgoCD components to be ready
echo ">>> Waiting for ArgoCD components to be ready..."
sleep 15

# Step 4.4: Wait for ArgoCD Service to be ready
echo ">>> Waiting for ArgoCD Service to be ready..."
sleep 5

# Step 4.5: Deploy ArgoCD Ingress
echo ">>> Deploying ArgoCD Ingress..."
kubectl apply -f config/k8s/argocd/argocd-ingress.yaml

# Step 4.6: Wait for ArgoCD to be fully ready
echo ">>> Waiting for ArgoCD to be fully ready..."
sleep 10

# Step 4.7: Deploy ArgoCD Applications (GitOps)
echo ">>> Deploying ArgoCD Applications..."
kubectl apply -f config/k8s/argocd/base-application.yaml
kubectl apply -f config/k8s/argocd/llm-application.yaml
kubectl apply -f config/k8s/argocd/monitoring-application.yaml
kubectl apply -f config/k8s/argocd/argocd-ingress-application.yaml

# Step 4.8: Display ArgoCD initial admin password
echo ">>> ArgoCD initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d && echo || echo "⚠ Password may not be generated yet, run later: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo ">>> ArgoCD UI: Access via Ingress after deployment (check ingress configuration)"

echo "================ Step 5: Install ArgoCD Image Updater ==================="
# Step 5.1: Create required Secrets before installing Image Updater
echo ">>> Creating Docker Registry Secret..."
if [ -f "config/k8s/argocd/image-updater/docker-registry-secret.yaml" ]; then
    kubectl apply -f config/k8s/argocd/image-updater/docker-registry-secret.yaml
    echo "✔ Docker Registry Secret created"
else
    echo "⚠ Warning: docker-registry-secret.yaml not found, Image Updater may not be able to pull private images"
fi

echo ">>> Creating Git Credentials Secret..."
if [ -f "config/k8s/argocd/image-updater/git-credentials-secret.yaml" ]; then
    kubectl apply -f config/k8s/argocd/image-updater/git-credentials-secret.yaml
    echo "✔ Git Credentials Secret created"
else
    echo "⚠ Warning: git-credentials-secret.yaml not found, Image Updater may not be able to write back to Git"
fi

# Step 5.2: Check Helm dependency
echo ">>> Checking Helm installation..."
if ! command -v helm >/dev/null 2>&1; then
    echo "❌ Helm not found. Please install helm before installing ArgoCD Image Updater."
    echo "   Run: curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
    exit 1
fi
echo "✔ Helm is installed: $(helm version --short)"

# Step 5.3: Add Argo Helm repository
echo ">>> Adding Argo Helm repository..."
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || echo "⚠ Helm repo may already exist"
helm repo update

# Step 5.4: Install ArgoCD Image Updater using Helm
echo ">>> Installing ArgoCD Image Updater using Helm..."
ARGOCD_IMAGE_UPDATER_CHART_VERSION="0.10.0"
if [ -f "config/k8s/argocd/image-updater/values.yaml" ]; then
    helm upgrade --install argocd-image-updater argo/argocd-image-updater \
      --version "${ARGOCD_IMAGE_UPDATER_CHART_VERSION}" \
      -n argocd \
      --create-namespace \
      -f config/k8s/argocd/image-updater/values.yaml
    echo "✔ Image Updater installed with custom values (version: ${ARGOCD_IMAGE_UPDATER_CHART_VERSION})"
else
    helm upgrade --install argocd-image-updater argo/argocd-image-updater \
      --version "${ARGOCD_IMAGE_UPDATER_CHART_VERSION}" \
      -n argocd \
      --create-namespace
    echo "✔ Image Updater installed with default values (version: ${ARGOCD_IMAGE_UPDATER_CHART_VERSION})"
fi

# Step 5.5: Wait for Image Updater to be ready
echo ">>> Waiting for ArgoCD Image Updater to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment/argocd-image-updater -n argocd 2>/dev/null || \
  echo "⚠ Image Updater may not be ready yet, continuing..."

# Step 5.6: Check status
echo ">>> Checking ArgoCD Image Updater status..."
kubectl get pods -n argocd | grep image-updater || echo "⚠ Image Updater may not be ready yet"

# Step 5.7: Display configuration info
echo ""
echo ">>> 📝 Image Updater Configuration:"
echo "   - Installed via Helm chart (argo/argocd-image-updater)"
echo "   - Docker Registry Secret: docker-registry-secret (for pulling private images)"
echo "   - Git Credentials Secret: git-credentials (for writing back to Git)"
echo "   - Update interval: 2 minutes (default)"
echo "   - Annotations are in Deployment YAML files in Git (the only source of truth)"
echo "   - Reference: config/k8s/argocd/image-updater/deployment-example.yaml"

echo "================ Step 6: Check Status ==================="
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get svc -A

echo ""
echo "=========================================================="
echo "🚀 Infrastructure deployed successfully from SYSTEM NODE (as control plane)!"
echo ""
echo "📋 Deployment Notes:"
echo "   - Infrastructure (ingress-nginx, ArgoCD) has been deployed"
echo "   - ArgoCD Applications have been created and will sync and deploy all services from Git repository"
echo "   - All services (LLM Web/API/Router/Workers/Monitoring) will be managed by ArgoCD"
echo "   - All images are public, no image pull secrets required"
echo ""
echo "🔍 Check Status:"
echo "   - Ingress (using hostNetwork, accessible via node IP):"
echo "     kubectl get svc -n ingress-nginx"
echo "   - ArgoCD Applications status:"
echo "     kubectl get applications -n argocd"
echo "   - ArgoCD UI:"
echo "     Access ArgoCD via Ingress (check ingress configuration)"
echo "   - ArgoCD admin password:"
echo "     kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "🌐 Service Access Addresses (after ArgoCD sync):"
echo "   - LLM Web:    Access via Ingress (check ingress configuration)"
echo "   - LLM API:    Access via Ingress (check ingress configuration)"
echo "   - Grafana:    Access via Ingress (check ingress configuration)"
echo "   - ArgoCD:     Access via Ingress (check ingress configuration)"
echo ""
echo "📝 Next Steps:"
echo "   1. Ensure Git repository contains all YAML files"
echo "   2. Check Applications sync status in ArgoCD UI"
echo "   3. If you need to use Image Updater, configure Docker Registry and Git credentials"
echo "=========================================================="
echo ""
echo "🎉🎉🎉 完整部署流程完成！====="
