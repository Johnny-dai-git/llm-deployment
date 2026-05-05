#!/bin/bash
set -e

# ======= 配置区域(可用环境变量覆盖) =======
GITHUB_USERNAME="${GITHUB_USERNAME:-Johnny-dai-git}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_REPO="${GITHUB_REPO:-llm-deployment}"
# 默认用 telemetry 分支(开发主线),线上稳定后可切回 main
GITHUB_BRANCH="${GITHUB_BRANCH:-telemetry}"

# 存储设备:台式机/服务器走 /dev/sda4,笔记本上没这分区时 fallback 到项目目录
# fallback 路径:脚本会再拼一层 /k8s,所以最终 PV 落在
#   /home/johnny/Desktop/projects/llm-server/data/k8s
# 优点:跟项目代码同一棵目录树,重启保留,备份迁移方便,跟 etcd/containerd 不抢 IO
STORAGE_DEVICE="${STORAGE_DEVICE:-/dev/sda4}"
STORAGE_FALLBACK_PATH="${STORAGE_FALLBACK_PATH:-/home/johnny/Desktop/projects/llm-server/data}"

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
# Phase 2.5: containerd 配置对齐
# ----------------------------------------------------------------
# 这一步要解决两个互相纠缠的坑,顺序很重要:
#
# 坑 1 — cgroup driver 不一致(必修):
#   Ubuntu 默认 cgroup v2 + kubeadm kubelet cgroupDriver=systemd,
#   但 containerd 如果用编译进去的默认配置(没有 /etc/containerd/config.toml),
#   默认 SystemdCgroup=false,用 cgroupfs。两边不一致 → kubelet 起不来
#   static pod(etcd/apiserver/controller-manager/scheduler 启动 ~14s 后被
#   SIGTERM,死循环重启)。
#   修复:生成默认 config.toml 并把所有 SystemdCgroup 改成 true。
#
# 坑 2 — nvidia runtime handler 丢失(GPU 节点必修):
#   生成默认配置会擦掉 nvidia-container-toolkit 注入的 runtimes.nvidia
#   block。结果:RuntimeClass 'nvidia' 的 pod(vllm-worker / dcgm-exporter)
#   会一直 ContainerCreating,Events 里报
#     "no runtime for 'nvidia' is configured"
#   修复:用 nvidia-ctk 把 nvidia runtime 注回 containerd 配置。
#   nvidia-ctk 可能把新加的 nvidia block 的 SystemdCgroup 写成 false,
#   所以最后再做一次 sed 'true' 兜底。
#
# 必须放在 system.sh(kubeadm init)之前,否则控制面起来就崩。
# ================================================================
echo ">>> Phase 2.5: 对齐 containerd 配置(cgroup + nvidia runtime)"
sudo mkdir -p /etc/containerd
NEED_RESTART_CONTAINERD=0

# (1) 确保 SystemdCgroup = true
if [ ! -f /etc/containerd/config.toml ] || ! grep -q "SystemdCgroup = true" /etc/containerd/config.toml 2>/dev/null; then
    echo "    - 生成默认 containerd 配置并启用 SystemdCgroup"
    sudo containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    NEED_RESTART_CONTAINERD=1
else
    echo "    ✔ containerd 已是 SystemdCgroup=true"
fi

# (2) GPU 节点:把 nvidia runtime handler 注入 containerd 配置
if [ "${HAS_GPU}" -eq 1 ]; then
    if command -v nvidia-ctk >/dev/null 2>&1; then
        if ! grep -q 'runtimes\.nvidia' /etc/containerd/config.toml 2>/dev/null; then
            echo "    - 用 nvidia-ctk 注入 nvidia runtime handler"
            sudo nvidia-ctk runtime configure --runtime=containerd --config=/etc/containerd/config.toml
            # nvidia-ctk 可能在新加的 block 里把 SystemdCgroup 写成 false,统一改回 true
            sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
            NEED_RESTART_CONTAINERD=1
        else
            echo "    ✔ containerd 已有 nvidia runtime handler"
        fi
    else
        echo "    ⚠️  HAS_GPU=1 但找不到 nvidia-ctk,RuntimeClass 'nvidia' 的 pod 会卡住"
        echo "       请确认 all_install.sh 装了 nvidia-container-toolkit"
    fi
fi

# (3) 需要重启才生效
if [ "${NEED_RESTART_CONTAINERD}" -eq 1 ]; then
    echo "    - 重启 containerd 让配置生效"
    sudo systemctl restart containerd
    for i in $(seq 1 10); do
        [ -S /run/containerd/containerd.sock ] && break
        sleep 1
    done
fi
echo "    ✔ Phase 2.5 完成"

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

# ----------------------------------------------------------------
# 先 apply PriorityClass(kps 的 helm values 会引用它,如果先装 helm
# 后 apply,helm 会抱怨 PriorityClass 不存在)
# 见 priority-classes.yaml 里两档:
#   monitoring-critical  (100000) Grafana / Prometheus / Alertmanager
#   monitoring-standard  (50000)  node-exporter / kube-state-metrics
# ----------------------------------------------------------------
echo "===== Applying PriorityClasses for monitoring stack ====="
kubectl apply -f "${CONTROL_DIR}/helm/monitoring/priority-classes.yaml"

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
# NVIDIA DCGM Grafana Dashboard 自动 import (仅 GPU 节点)
# ----------------------------------------------------------------
# 思路:
#   kube-prometheus-stack 自带 grafana-sc-dashboard sidecar,
#   它会把所有带 label `grafana_dashboard=1` 的 ConfigMap 自动转成
#   dashboard 写到 /tmp/dashboards/。我们下载 NVIDIA 官方 dashboard
#   12239 的 JSON,塞进 ConfigMap,sidecar 就会接管。
#
# 不靠 Grafana admin API(那个要密码,且在匿名 admin 模式下 401)。
# 不靠 helm values(改动 kps 还要 helm upgrade,代价大)。
# 这条路 idempotent,反复跑不会出错。
# ================================================================
if [ "${HAS_GPU}" -eq 1 ]; then
    echo "===== Installing NVIDIA DCGM Grafana dashboard ====="
    DCGM_DASHBOARD=/tmp/dcgm-dashboard.json

    # 下载 NVIDIA 官方 DCGM Exporter Dashboard (id=12239) latest revision
    if curl -sfL "https://grafana.com/api/dashboards/12239/revisions/latest/download" -o "${DCGM_DASHBOARD}"; then
        DCGM_SIZE=$(wc -c < "${DCGM_DASHBOARD}" 2>/dev/null || echo 0)
        if [ "${DCGM_SIZE}" -lt 5000 ]; then
            echo "⚠️  DCGM dashboard 下载内容异常(size=${DCGM_SIZE} < 5KB),跳过"
        else
            # 替换 datasource 占位符为实际 datasource 名(kube-prometheus-stack 默认叫 'Prometheus')
            sed -i 's|${DS_PROMETHEUS}|Prometheus|g' "${DCGM_DASHBOARD}"

            # 创建带 grafana_dashboard=1 label 的 ConfigMap,sidecar 自动加载
            kubectl -n monitoring create configmap nvidia-dcgm-dashboard \
                --from-file=dcgm-dashboard.json="${DCGM_DASHBOARD}" \
                --dry-run=client -o yaml \
                | kubectl label --local -f - grafana_dashboard=1 -o yaml --dry-run=client \
                | kubectl apply -f -

            # 等 sidecar 把文件写入 grafana 容器
            sleep 30

            # 让 Grafana 重新扫描 provisioning 目录(SIGHUP 让其 reload 配置)
            GRAFANA_POD=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
            if [ -n "${GRAFANA_POD}" ]; then
                kubectl exec -n monitoring "${GRAFANA_POD}" -c grafana -- killall -SIGHUP grafana 2>/dev/null || true
                echo "✓ DCGM dashboard 已 import,在 Grafana 搜索 'nvidia' 或 'dcgm' 即可看到"
            else
                echo "⚠️  Grafana pod 未找到,dashboard 文件已写入 ConfigMap,Grafana 启动后自动加载"
            fi
        fi
    else
        echo "⚠️  无法从 grafana.com 下载 DCGM dashboard(网络或 URL 失效),跳过"
    fi
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
