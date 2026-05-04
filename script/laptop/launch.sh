#!/bin/bash
set -e

# ======= 配置区域(可用环境变量覆盖) =======
GITHUB_USERNAME="${GITHUB_USERNAME:-Johnny-dai-git}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_REPO="${GITHUB_REPO:-llm-deployment}"
# 默认用 telemetry 分支(开发主线),线上稳定后可切回 main
GITHUB_BRANCH="${GITHUB_BRANCH:-telemetry}"

# 存储设备:笔记本上多半没有 /dev/sda4,会自动 fallback 到 /var/lib
STORAGE_DEVICE="${STORAGE_DEVICE:-/dev/sda4}"
STORAGE_FALLBACK_PATH="${STORAGE_FALLBACK_PATH:-/var/lib}"

if [ -n "${GITHUB_TOKEN}" ]; then
  GITHUB_URL="https://${GITHUB_TOKEN}@github.com/${GITHUB_USERNAME}/${GITHUB_REPO}.git"
else
  GITHUB_URL="https://github.com/${GITHUB_USERNAME}/${GITHUB_REPO}.git"
  echo "⚠️  GITHUB_TOKEN not set, using git credential helper"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# launch.sh 现在在 script/laptop/ 下,repo 根需要再上一层
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
INSTALL_DIR="${SCRIPT_DIR}"
CONTROL_DIR="${REPO_DIR}/tools"

# GPU 检测(全局,后续 Phase 复用)
HAS_GPU=0
if lspci 2>/dev/null | grep -i nvidia >/dev/null 2>&1; then
  HAS_GPU=1
fi

echo "===== Kubernetes control-plane bootstrap start ====="
echo ">>> Branch:    ${GITHUB_BRANCH}"
echo ">>> Has GPU:   $([ $HAS_GPU -eq 1 ] && echo yes || echo no)"
echo ">>> Storage:   ${STORAGE_DEVICE}(找不到时 fallback 到 ${STORAGE_FALLBACK_PATH})"
echo ""

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

if [ "${HAS_GPU}" -eq 1 ]; then
    echo ">>> GPU detected, labeling node 'system' with gpu-node=true"
    kubectl label node system gpu-node=true --overwrite || true
else
    echo ">>> No GPU detected, skipping gpu-node label"
    echo "⚠️  vllm-worker 需要 nvidia.com/gpu,本节点无 GPU 时它将 Pending"
fi

# ================================================================
# Phase 4: infra + GPU(只在 GPU 存在时装)
# ================================================================
if [ "${HAS_GPU}" -eq 1 ]; then
    echo ">>> 安装 NVIDIA device plugin..."
    kubectl apply -f "${CONTROL_DIR}/system/nvidia-device-plugin.yaml" || true
    kubectl rollout status ds/nvidia-device-plugin-daemonset -n kube-system --timeout=60s || true

    # RuntimeClass
    kubectl get runtimeclass nvidia >/dev/null 2>&1 || \
    kubectl apply -f "${CONTROL_DIR}/system/runtimeclass-nvidia.yaml"
else
    echo ">>> 无 GPU,跳过 NVIDIA device plugin 与 RuntimeClass"
fi

# ================================================================
# Storage (local-path)
# 优先用 STORAGE_DEVICE 指定的分区,找不到就 fallback 到本地目录
# ================================================================
MOUNT_POINT=""
if [ -b "${STORAGE_DEVICE}" ]; then
    MOUNT_POINT=$(findmnt -n -o TARGET "${STORAGE_DEVICE}" 2>/dev/null || true)
    [ -z "${MOUNT_POINT}" ] && \
      MOUNT_POINT=$(lsblk -n -o MOUNTPOINT "${STORAGE_DEVICE}" 2>/dev/null | head -1)
fi

if [ -z "${MOUNT_POINT}" ]; then
    echo "⚠️  ${STORAGE_DEVICE} 未挂载或不存在,fallback 到 ${STORAGE_FALLBACK_PATH}"
    MOUNT_POINT="${STORAGE_FALLBACK_PATH}"
fi

LOCAL_STORAGE_PATH="${MOUNT_POINT}/k8s"
echo ">>> Local storage path: ${LOCAL_STORAGE_PATH}"
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
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ || true
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
# Monitoring(kube-prometheus-stack + DCGM)
# --reuse-values=false:确保 kps-values.yaml 改动后真的生效
# ================================================================
echo "===== Installing kube-prometheus-stack ====="
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f "${CONTROL_DIR}/helm/monitoring/kps-values.yaml" \
  --reuse-values=false \
  --wait --timeout 10m

# DCGM 只在 GPU 存在时装
if [ "${HAS_GPU}" -eq 1 ]; then
    echo "===== Installing DCGM exporter ====="
    helm upgrade --install dcgm nvidia/dcgm-exporter \
      -n monitoring \
      -f "${CONTROL_DIR}/helm/monitoring/dcgm/values.yaml" \
      --reuse-values=false \
      --wait --timeout 5m
else
    echo ">>> 无 GPU,跳过 DCGM exporter"
fi

# ================================================================
# HPA support: metrics-server + prometheus-adapter
# ================================================================
# metrics-server: 提供 K8s 资源指标(CPU/内存),HPA 用 Resource 类型时必需
# --kubelet-insecure-tls 在自签证书的 kubeadm 集群上需要,生产环境改成正式证书
echo "===== Installing metrics-server (for CPU/memory HPA) ====="
helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system \
  --set 'args={--kubelet-insecure-tls,--kubelet-preferred-address-types=InternalIP}' \
  --reuse-values=false \
  --wait --timeout 5m

# prometheus-adapter: 把 Prometheus 任意指标变成 K8s custom metrics API
# 让 HPA 能基于 vllm:num_requests_waiting 这种业务指标扩缩
echo "===== Installing prometheus-adapter (for custom metrics HPA) ====="
helm upgrade --install prometheus-adapter prometheus-community/prometheus-adapter \
  -n monitoring \
  -f "${CONTROL_DIR}/helm/monitoring/prometheus-adapter-values.yaml" \
  --reuse-values=false \
  --wait --timeout 5m

# ================================================================
# Landing Page
# ================================================================
echo "===== Deploying Landing Page ====="

echo ">>> Applying Landing Page ConfigMap..."
kubectl apply -f "${CONTROL_DIR}/llm/landing/landing-page-configmap.yaml"

echo ">>> Applying Landing Page Deployment..."
kubectl apply -f "${CONTROL_DIR}/llm/landing/landing-nginx-deployment.yaml"

echo ">>> Applying Landing Page Service..."
kubectl apply -f "${CONTROL_DIR}/llm/landing/landing-service.yaml"

echo ">>> Applying Landing Page Ingress..."
kubectl apply -f "${CONTROL_DIR}/llm/landing/landing-ingress.yaml"

echo "✅ Landing Page deployed"

# ================================================================
# Final check
# ================================================================
echo ""
echo "===== Final cluster state ====="
kubectl get pods -A
echo ""
kubectl get nodes -o wide
echo ""
echo "===== Access URLs (hostNetwork=true,直接绑你笔记本 80 端口) ====="
echo "  Web UI:       http://localhost/web"
echo "  API:          http://localhost/api/v1/chat/completions"
echo "  Grafana:      http://localhost/grafana   (匿名 Admin 进得去)"
echo "  Prometheus:   http://localhost/prometheus"
echo "  Landing:      http://localhost/"
echo ""
echo "===== Verify monitoring is actually scraping ====="
echo "  在 Prometheus UI 看 targets 页面,应该看到:"
echo "    - serviceMonitor/llm/llm-api/0   (UP)"
echo "    - serviceMonitor/llm/vllm-worker/0 (UP)"
if [ "${HAS_GPU}" -eq 1 ]; then
    echo "    - serviceMonitor/monitoring/dcgm-exporter/0 (UP)"
fi
echo ""

if [ "${HAS_GPU}" -eq 0 ]; then
    echo "⚠️  本节点无 GPU,vllm-worker 会停在 Pending 状态:"
    echo "    nodeSelector gpu-node=true 没有节点匹配,且 nvidia.com/gpu: 1 不可满足"
    echo "    要让 vllm-worker 真跑起来,必须在带 NVIDIA GPU 的节点上部署"
    echo ""
fi

echo "🎉 Kubernetes + ArgoCD + Image Updater bootstrap DONE"
