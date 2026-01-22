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
echo "===== Phase 4: 部署基础设施（MetalLB, ingress-nginx, ArgoCD）====="

# 切换到 control 目录（因为 run_control 的路径是相对于 control 目录的）
cd "${CONTROL_DIR}"

echo "================ Step 1: Apply namespaces ================"
kubectl apply -f config/k8s/base/namespaces/

echo "================ Step 1.5: Create ghcr-secret ============"
# Create ghcr.io authentication Secret (for pulling private images)
echo ">>> Creating ghcr-secret (GitHub Container Registry authentication)..."
if [ -f "config/k8s/llm/secrets/ghcr-secret.yaml" ]; then
    kubectl apply -f config/k8s/llm/secrets/ghcr-secret.yaml
    echo "✔ ghcr-secret created"
    echo ">>> Verifying ghcr-secret status:"
    kubectl get secret ghcr-secret -n llm
    echo "✔ ghcr-secret verification successful"
else
    echo "⚠ Warning: config/k8s/llm/secrets/ghcr-secret.yaml file does not exist"
    echo "   Please ensure GitHub token and username are configured"
fi

echo "================ Step 2: Label nodes ====================="
SYSTEM_NODE="system"
echo "Labeling system node..."
kubectl label node $SYSTEM_NODE system=true ingress=true --overwrite

echo "================ Step 3: Deploy MetalLB =================="
# Step 3.1: Install official MetalLB
echo ">>> Installing official MetalLB..."
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.5/config/manifests/metallb-native.yaml

# Step 3.2: Wait for MetalLB components to be ready
echo ">>> Waiting for MetalLB components to be ready..."
sleep 10

# Step 3.3: Wait for MetalLB webhook to be ready (critical for CR validation)
echo ">>> Waiting for MetalLB webhook to be ready..."
WEBHOOK_READY=false
MAX_WAIT=120  # 最多等待 120 秒
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
  # 检查 controller deployment 是否就绪（webhook 是 controller 的一部分）
  CONTROLLER_READY=$(kubectl get deployment controller -n metallb-system -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
  
  # 检查 webhook service 的 endpoint 是否存在且有地址
  ENDPOINT_IP=$(kubectl get endpoints -n metallb-system metallb-webhook-service -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || echo "")
  
  # 检查 validatingwebhookconfiguration 是否存在
  WEBHOOK_CONFIG_EXISTS=$(kubectl get validatingwebhookconfiguration metallb-webhook-configuration -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")
  
  if [ "$CONTROLLER_READY" = "True" ] && [ -n "$ENDPOINT_IP" ] && [ -n "$WEBHOOK_CONFIG_EXISTS" ]; then
    # 额外检查：确保 endpoint 确实指向了 pod
    ENDPOINT_PORT=$(kubectl get endpoints -n metallb-system metallb-webhook-service -o jsonpath='{.subsets[0].ports[0].port}' 2>/dev/null || echo "")
    if [ -n "$ENDPOINT_PORT" ]; then
      WEBHOOK_READY=true
      echo "✔ MetalLB webhook is ready (controller: $CONTROLLER_READY, endpoint: $ENDPOINT_IP:$ENDPOINT_PORT)"
      break
    fi
  fi
  
  WAIT_COUNT=$((WAIT_COUNT + 5))
  echo "   Waiting for webhook... (${WAIT_COUNT}s/${MAX_WAIT}s)"
  sleep 5
done

if [ "$WEBHOOK_READY" = "false" ]; then
  echo "⚠ Warning: MetalLB webhook may not be fully ready, but continuing..."
  echo "   If IP pool creation fails, wait a bit longer and retry manually"
  echo "   You can check webhook status with: kubectl get pods,svc,endpoints -n metallb-system"
fi

# Step 3.4: Patch controller resources
echo ">>> Configuring MetalLB controller resources..."
kubectl -n metallb-system patch deployment controller \
  --type='json' \
  -p='[
    {"op":"add","path":"/spec/template/spec/containers/0/resources",
     "value":{"requests":{"cpu":"100m","memory":"128Mi"},
              "limits":{"cpu":"300m","memory":"512Mi"}}}
  ]' || echo "⚠ Controller may not be ready yet, manual patch required later"

# Step 3.5: Patch speaker resources
echo ">>> Configuring MetalLB speaker resources..."
kubectl -n metallb-system patch daemonset speaker \
  --type='json' \
  -p='[
    {"op":"add","path":"/spec/template/spec/containers/0/resources",
     "value":{"requests":{"cpu":"50m","memory":"64Mi"},
              "limits":{"cpu":"200m","memory":"256Mi"}}}
  ]' || echo "⚠ Speaker may not be ready yet, manual patch required later"

# Step 3.6: Apply MetalLB IP pool configuration (with retry logic)
echo ">>> Applying MetalLB IP pool configuration..."
RETRY_COUNT=0
MAX_RETRIES=3
IP_POOL_APPLIED=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  # 尝试应用配置，捕获错误输出
  APPLY_OUTPUT=$(kubectl apply -f config/k8s/base/metallb/metallb-ip-pool.yaml 2>&1)
  APPLY_EXIT_CODE=$?
  
  if [ $APPLY_EXIT_CODE -eq 0 ]; then
    IP_POOL_APPLIED=true
    echo "✔ MetalLB IP pool configuration applied successfully"
    break
  else
    RETRY_COUNT=$((RETRY_COUNT + 1))
    # 检查是否是 webhook 连接错误
    if echo "$APPLY_OUTPUT" | grep -q "connection refused\|failed calling webhook"; then
      if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
        echo "   ⚠ Webhook not ready yet, retry ${RETRY_COUNT}/${MAX_RETRIES}: Waiting 5 more seconds..."
        sleep 5
      else
        echo "   ❌ Failed to apply IP pool after ${MAX_RETRIES} attempts (webhook still not ready)"
        echo "   Error: $APPLY_OUTPUT"
        echo "   Please wait a bit longer and retry manually:"
        echo "   kubectl apply -f config/k8s/base/metallb/metallb-ip-pool.yaml"
      fi
    else
      # 其他类型的错误，直接显示并退出
      echo "   ❌ Failed to apply IP pool configuration:"
      echo "   $APPLY_OUTPUT"
      break
    fi
  fi
done

kubectl get configmap -n metallb-system || true

echo "================ Step 4: Deploy ingress-nginx ============"
kubectl apply -f config/k8s/base/ingress-nginx/

echo "================ Step 5: Deploy ArgoCD ==================="
# Step 5.1: Create ArgoCD namespace
echo ">>> Creating ArgoCD namespace..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Step 5.2: Install official ArgoCD
echo ">>> Installing official ArgoCD..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Step 5.3: Wait for ArgoCD components to be ready
echo ">>> Waiting for ArgoCD components to be ready..."
sleep 15

# Step 5.4: Wait for ArgoCD Service to be ready
echo ">>> Waiting for ArgoCD Service to be ready..."
sleep 5

# Step 5.5: Deploy ArgoCD Ingress
echo ">>> Deploying ArgoCD Ingress..."
kubectl apply -f config/k8s/argocd/argocd-ingress.yaml

# Step 5.6: Wait for ArgoCD to be fully ready
echo ">>> Waiting for ArgoCD to be fully ready..."
sleep 10

# Step 5.7: Deploy ArgoCD Applications (GitOps)
echo ">>> Deploying ArgoCD Applications..."
kubectl apply -f config/k8s/argocd/base-application.yaml
kubectl apply -f config/k8s/argocd/llm-application.yaml
kubectl apply -f config/k8s/argocd/monitoring-application.yaml
kubectl apply -f config/k8s/argocd/argocd-ingress-application.yaml

# Step 5.8: Display ArgoCD initial admin password
echo ">>> ArgoCD initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d && echo || echo "⚠ Password may not be generated yet, run later: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
SYSTEM_NODE_IP=$(curl -s ifconfig.me 2>/dev/null || echo "149.165.147.30")
echo ">>> ArgoCD UI: http://${SYSTEM_NODE_IP}/argocd (access after Ingress takes effect)"

echo "================ Step 6: Install ArgoCD Image Updater ==================="
# Step 6.1: Create required Secrets before installing Image Updater
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

# Step 6.2: Check Helm dependency
echo ">>> Checking Helm installation..."
if ! command -v helm >/dev/null 2>&1; then
    echo "❌ Helm not found. Please install helm before installing ArgoCD Image Updater."
    echo "   Run: curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
    exit 1
fi
echo "✔ Helm is installed: $(helm version --short)"

# Step 6.3: Add Argo Helm repository
echo ">>> Adding Argo Helm repository..."
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || echo "⚠ Helm repo may already exist"
helm repo update

# Step 6.4: Install ArgoCD Image Updater using Helm
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

# Step 6.5: Wait for Image Updater to be ready
echo ">>> Waiting for ArgoCD Image Updater to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment/argocd-image-updater -n argocd 2>/dev/null || \
  echo "⚠ Image Updater may not be ready yet, continuing..."

# Step 6.6: Check status
echo ">>> Checking ArgoCD Image Updater status..."
kubectl get pods -n argocd | grep image-updater || echo "⚠ Image Updater may not be ready yet"

# Step 6.7: Display configuration info
echo ""
echo ">>> 📝 Image Updater Configuration:"
echo "   - Installed via Helm chart (argo/argocd-image-updater)"
echo "   - Docker Registry Secret: docker-registry-secret (for pulling private images)"
echo "   - Git Credentials Secret: git-credentials (for writing back to Git)"
echo "   - Update interval: 2 minutes (default)"
echo "   - Annotations are in Deployment YAML files in Git (the only source of truth)"
echo "   - Reference: config/k8s/argocd/image-updater/deployment-example.yaml"

echo "================ Step 7: Check Status ==================="
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get svc -A

echo ""
echo ">>> Verifying critical Secret status:"
kubectl get secret ghcr-secret -n llm || echo "⚠ ghcr-secret does not exist, please check"

echo ""
echo "=========================================================="
echo "🚀 Infrastructure deployed successfully from SYSTEM NODE (as control plane)!"
echo ""
echo "📋 Deployment Notes:"
echo "   - Infrastructure (MetalLB, ingress-nginx, ArgoCD) has been deployed"
echo "   - ghcr-secret has been created and can be used to pull ghcr.io private images"
echo "   - ArgoCD Applications have been created and will sync and deploy all services from Git repository"
echo "   - All services (LLM Web/API/Router/Workers/Monitoring) will be managed by ArgoCD"
echo ""
echo "🔍 Check Status:"
echo "   - Ingress External IP:"
echo "     kubectl get svc -n ingress-nginx"
echo "   - ArgoCD Applications status:"
echo "     kubectl get applications -n argocd"
echo "   - ghcr-secret status:"
echo "     kubectl get secret ghcr-secret -n llm"
echo "   - ArgoCD UI:"
echo "     http://${SYSTEM_NODE_IP}/argocd"
echo "   - ArgoCD admin password:"
echo "     kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "🌐 Service Access Addresses (after ArgoCD sync):"
echo "   - LLM Web:    http://${SYSTEM_NODE_IP}/"
echo "   - LLM API:    http://${SYSTEM_NODE_IP}/api"
echo "   - Grafana:    http://${SYSTEM_NODE_IP}/grafana"
echo "   - ArgoCD:     http://${SYSTEM_NODE_IP}/argocd"
echo ""
echo "📝 Next Steps:"
echo "   1. Ensure Git repository contains all YAML files"
echo "   2. Check Applications sync status in ArgoCD UI"
echo "   3. If you need to use Image Updater, configure Docker Registry and Git credentials"
echo "=========================================================="
echo ""
echo "🎉🎉🎉 完整部署流程完成！====="
