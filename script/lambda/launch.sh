#!/bin/bash
# =====================================================================
# Lambda Labs A100 — 一键 bootstrap (launch.sh)
# ---------------------------------------------------------------------
# 与 script/laptop/launch.sh 的差异:
#   - 删除 HAS_GPU 检测分支 —— Lambda 永远是 GPU 节点
#   - STORAGE_FALLBACK_PATH:  /mnt/k8s (而不是 /home/johnny/...)
#   - 调用 script/lambda/all_install.sh + system.sh (本目录)
#   - 末尾 ACCESS URL 用 public IP (161.153.48.3) 而不是 localhost
#
# 跑这个之前先确保:
#   1. all_install.sh 已经跑过(MIG 7 个实例已切好)
#   2. script/lambda/download-model.sh 已经跑过(/mnt/models/qwen2.5-0.5b)
#   3. Lambda 防火墙已开 80 端口
# =====================================================================
set -e

# ======= 配置区域(可用环境变量覆盖) =======
GITHUB_USERNAME="${GITHUB_USERNAME:-Johnny-dai-git}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_REPO="${GITHUB_REPO:-llm-deployment}"
# Lambda 跟 GCP_BRANCH 走
GITHUB_BRANCH="${GITHUB_BRANCH:-GCP_BRANCH}"

# Lambda 没有 /dev/sda4 这种盘,直接 fallback 到 /mnt/k8s
STORAGE_DEVICE="${STORAGE_DEVICE:-/dev/none}"
STORAGE_FALLBACK_PATH="${STORAGE_FALLBACK_PATH:-/mnt/k8s}"

if [ -n "${GITHUB_TOKEN}" ]; then
  GITHUB_URL="https://${GITHUB_TOKEN}@github.com/${GITHUB_USERNAME}/${GITHUB_REPO}.git"
else
  GITHUB_URL="https://github.com/${GITHUB_USERNAME}/${GITHUB_REPO}.git"
  echo "⚠️  GITHUB_TOKEN not set, using git credential helper"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# launch.sh 在 script/lambda/ 下,repo 根再上两层
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
INSTALL_DIR="${SCRIPT_DIR}"
CONTROL_DIR="${REPO_DIR}/tools"

echo "===== Kubernetes control-plane bootstrap (Lambda A100) ====="
echo ">>> Branch:    ${GITHUB_BRANCH}"
echo ">>> Repo dir:  ${REPO_DIR}"
echo ">>> Storage:   ${STORAGE_DEVICE} (fallback ${STORAGE_FALLBACK_PATH})"
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
# Phase 2: common install (k8s + helm + MIG 配置)
# ================================================================
cd "${INSTALL_DIR}"
sudo bash all_install.sh

# ================================================================
# Phase 2.5: containerd 配置对齐 (cgroup + nvidia runtime + docker.io mirror)
# ----------------------------------------------------------------
# all_install.sh 已经把 SystemdCgroup 写好了,这里再做两件事:
#
#   (a) 注入 nvidia runtime handler
#       nvidia-ctk runtime configure 会在新增的 nvidia block 里把
#       SystemdCgroup 写成 false → 必须再 sed 一遍
#
#   (b) 加 docker.io 的 registry mirror
#       Lambda 出口 IP 拉 docker.io 经常被 throttle,导致 helper pod /
#       grafana 镜像无限 ContainerCreating。用 mirror.gcr.io (Google 维
#       护的 docker hub 镜像) 几乎从不卡。多次踩坑后写进默认配置。
#
# 必须在 system.sh (kubeadm init) 之前完成,否则控制面起来就崩。
# ================================================================
echo ">>> Phase 2.5: 校准 containerd (nvidia runtime + docker.io mirror)"
NEED_RESTART_CONTAINERD=0

# (a) nvidia runtime
if command -v nvidia-ctk >/dev/null 2>&1; then
    if ! grep -q 'runtimes\.nvidia' /etc/containerd/config.toml 2>/dev/null; then
        echo "    - 用 nvidia-ctk 注入 nvidia runtime handler"
        sudo nvidia-ctk runtime configure --runtime=containerd --config=/etc/containerd/config.toml
        sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
        NEED_RESTART_CONTAINERD=1
    else
        echo "    ✔ containerd 已有 nvidia runtime handler"
    fi
else
    echo "    ⚠️  找不到 nvidia-ctk,RuntimeClass 'nvidia' 的 pod 会卡住"
    exit 1
fi

# (b) docker.io mirror (Lambda 拉 docker hub 经常卡)
if ! grep -q 'mirrors\."docker.io"' /etc/containerd/config.toml 2>/dev/null; then
    echo "    - 加 docker.io mirror → mirror.gcr.io"
    # 在 [plugins."io.containerd.grpc.v1.cri".registry.mirrors] 那一行后面插入
    # docker.io mirror 块。如果该 anchor 行不存在(老 containerd 配置),
    # 直接 append 完整块到文件末尾。
    if grep -q '\[plugins\."io\.containerd\.grpc\.v1\.cri"\.registry\.mirrors\]' /etc/containerd/config.toml; then
        sudo sed -i '/\[plugins\."io\.containerd\.grpc\.v1\.cri"\.registry\.mirrors\]/a\        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]\n          endpoint = ["https://mirror.gcr.io", "https://registry-1.docker.io"]' \
            /etc/containerd/config.toml
    else
        sudo tee -a /etc/containerd/config.toml >/dev/null <<'EOF'

[plugins."io.containerd.grpc.v1.cri".registry.mirrors]
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
    endpoint = ["https://mirror.gcr.io", "https://registry-1.docker.io"]
EOF
    fi
    NEED_RESTART_CONTAINERD=1
else
    echo "    ✔ containerd 已有 docker.io mirror"
fi

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
# Phase 2.6: 通用 helper 函数 (后面所有 helm install 都用)
# ----------------------------------------------------------------
# Lambda 上踩过 3 次"kubelet image pull 卡死"的坑,根因是 kubelet
# 内部 pull 状态机有时会 wedge,即使 image 本地已有也死等。
# 解法是用 crictl 直接拉到 containerd cache,然后强删卡死 pod 让
# ReplicaSet/StatefulSet 重建,这次会从 cache 命中秒起。
#
# 这两个函数把这个套路标准化,任何 helm 装包前后调用即可。
# ================================================================

# 用 helm template 提取 chart 渲染后的所有 image,然后 crictl pull 一遍。
# 用法: prepull_helm_images <release> <chart> <namespace> [extra args...]
prepull_helm_images() {
    local release="$1"
    local chart="$2"
    local namespace="$3"
    shift 3

    echo ">>> Pre-pulling images for helm release '${release}'..."
    local images
    images=$(helm template "${release}" "${chart}" -n "${namespace}" "$@" 2>/dev/null \
             | grep -E "^\s*image:" \
             | awk '{print $2}' \
             | tr -d '"' \
             | sort -u)

    if [ -z "$images" ]; then
        echo "    (helm template 没产出 image,跳过)"
        return 0
    fi

    while read -r img; do
        [ -z "$img" ] && continue
        echo "    -> $img"
        sudo crictl pull "$img" >/dev/null 2>&1 || echo "       ⚠️  pull failed (会让 kubelet 自己重试)"
    done <<< "$images"
}

# 强删 namespace 下所有非 Running 的 pod,让 controller 重建。
# 用法: kick_stuck_pods <namespace>
kick_stuck_pods() {
    local namespace="$1"
    echo ">>> 强删 ${namespace} 下卡住的 pod (让 controller 重建用 cache)..."
    local stuck
    stuck=$(kubectl get pods -n "${namespace}" --no-headers 2>/dev/null \
            | awk '$3 != "Running" && $3 != "Completed" {print $1}')
    if [ -z "$stuck" ]; then
        echo "    (无卡死 pod)"
        return 0
    fi
    while read -r pod; do
        [ -z "$pod" ] && continue
        echo "    强删 $pod"
        kubectl delete pod -n "${namespace}" "$pod" --force --grace-period=0 2>/dev/null || true
    done <<< "$stuck"
}

# Chown Grafana 的 local-path PV 到 UID 472。
# 必须的:kps-values.yaml 里把 init-chown-data 关了(modern chart 用 non-root,
# 在 hostPath PV 上 chown 会撞 Permission denied),所以由 launch.sh 在
# 宿主机直接 chown 解决。fsGroup 对 hostPath 不生效。
chown_grafana_pv() {
    echo ">>> Chowning Grafana PV to UID 472:472..."
    local pv hostpath
    for i in $(seq 1 30); do
        pv=$(kubectl get pvc -n monitoring monitoring-grafana \
              -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)
        [ -n "$pv" ] && break
        sleep 2
    done
    if [ -z "$pv" ]; then
        echo "    ⚠️  PVC 还没 bound,跳过 chown(grafana 可能起不来)"
        return 1
    fi
    hostpath=$(kubectl get pv "$pv" -o jsonpath='{.spec.hostPath.path}' 2>/dev/null || true)
    if [ -z "$hostpath" ]; then
        echo "    ⚠️  PV ${pv} 没有 hostPath,跳过"
        return 1
    fi
    echo "    PV host path: $hostpath"
    sudo chown -R 472:472 "$hostpath"
    sudo chmod -R 775 "$hostpath"
    echo "    ✔ chown 完成"
}

# ================================================================
# Phase 3: k8s init
# ================================================================
sudo bash system.sh

# ================================================================
# Phase 3.5: Label node
# ================================================================
echo ">>> Labeling node 'system' with system=true, gpu-node=true"
kubectl label node system system=true --overwrite || true
kubectl label node system gpu-node=true --overwrite || true

# ================================================================
# Phase 4: NVIDIA device plugin (MIG single strategy)
# ================================================================
echo ">>> 安装 NVIDIA device plugin (MIG single strategy → 7 个 nvidia.com/gpu)"
kubectl apply -f "${CONTROL_DIR}/system/nvidia-device-plugin.yaml" || true
kubectl rollout status ds/nvidia-device-plugin-daemonset -n kube-system --timeout=120s || true

# RuntimeClass
kubectl get runtimeclass nvidia >/dev/null 2>&1 || \
kubectl apply -f "${CONTROL_DIR}/system/runtimeclass-nvidia.yaml"

# 验证 MIG 实例已被 k8s 看到
echo ">>> 验证 nvidia.com/gpu 资源数量(应该 = 7):"
kubectl get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}{"\n"}' || echo "(还没出现,稍等片刻再看 kubectl describe node)"

# ================================================================
# Storage (local-path)
# Lambda 上没有专门的 STORAGE_DEVICE 分区,直接 fallback 到 /mnt/k8s
# ================================================================
MOUNT_POINT=""
if [ -b "${STORAGE_DEVICE}" ]; then
    MOUNT_POINT=$(findmnt -n -o TARGET "${STORAGE_DEVICE}" 2>/dev/null || true)
    [ -z "${MOUNT_POINT}" ] && \
      MOUNT_POINT=$(lsblk -n -o MOUNTPOINT "${STORAGE_DEVICE}" 2>/dev/null | head -1)
fi

if [ -z "${MOUNT_POINT}" ]; then
    echo "ℹ️  ${STORAGE_DEVICE} 不存在,使用 fallback ${STORAGE_FALLBACK_PATH}"
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
# hostNetwork=true → 直接绑宿主机 :80,Lambda public IP 就能访问
# 也走 prepull 套路,避免 webhook-certgen job pull 卡死把 controller 拖住
# ================================================================
kubectl create namespace ingress-nginx --dry-run=client -o yaml | kubectl apply -f -

prepull_helm_images ingress-nginx ingress-nginx/ingress-nginx ingress-nginx \
    --set controller.hostNetwork=true \
    --set controller.dnsPolicy=ClusterFirstWithHostNet \
    --set controller.service.type=ClusterIP

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace \
  --set controller.hostNetwork=true \
  --set controller.dnsPolicy=ClusterFirstWithHostNet \
  --set controller.service.type=ClusterIP

kubectl rollout status deployment ingress-nginx-controller -n ingress-nginx --timeout=180s || true

# ================================================================
# ArgoCD
# ================================================================
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

prepull_helm_images argocd argo/argo-cd argocd \
    -f "${CONTROL_DIR}/helm/argocd/values.yaml"

helm upgrade --install argocd argo/argo-cd \
  -n argocd \
  -f "${CONTROL_DIR}/helm/argocd/values.yaml" \
  --wait --timeout 15m \
  || echo "⚠️  ArgoCD helm timeout,继续(controller 在追)"

# ================================================================
# ArgoCD Image Updater
# ================================================================
echo "===== Installing ArgoCD Image Updater ====="
kubectl get ns argocd || kubectl create ns argocd

kubectl apply -f "${CONTROL_DIR}/argocd-image-updater/argocd-image-updater-sa.yaml"
kubectl apply -f "${CONTROL_DIR}/argocd-image-updater/argocd-image-updater-clusterrole.yaml"
kubectl apply -f "${CONTROL_DIR}/argocd-image-updater/argocd-image-updater-clusterrolebinding.yaml"
kubectl apply -f "${CONTROL_DIR}/argocd-image-updater/argocd-image-updater-config.yaml"
kubectl apply -f "${CONTROL_DIR}/argocd-image-updater/argocd-image-updater-token.yaml" || true
kubectl apply -f "${CONTROL_DIR}/argocd-image-updater/argocd-image-updater-controller.yaml"

kubectl rollout status deployment/argocd-image-updater-controller -n argocd --timeout=5m || \
    echo "⚠️  Image Updater 仍在启动中..."

# ================================================================
# ArgoCD Applications
# ================================================================
echo "===== Deploying ArgoCD Applications ====="
kubectl apply -f "${CONTROL_DIR}/argocd-image-updater/llm-application.yaml"
sleep 5
kubectl get application llm-platform-services -n argocd || echo "⚠️  Application not found"

# ================================================================
# Monitoring
# ----------------------------------------------------------------
# 监控栈是镜像 pull 最容易踩坑的部分(grafana / kiwigrid 在 docker.io,
# Lambda 上经常卡几十分钟)。流程改成:
#   1. helm template 提取所有 image
#   2. 用 crictl 预拉到 containerd cache(走 mirror.gcr.io)
#   3. 再 helm install
#   4. install 完立刻 chown grafana PV(kps-values.yaml 关了 init-chown-data)
#   5. 强删任何还卡住的 pod(让 controller 重建,这次 cache 命中秒起)
# ================================================================
echo "===== Applying PriorityClasses for monitoring stack ====="
kubectl apply -f "${CONTROL_DIR}/helm/monitoring/priority-classes.yaml"

# 必须先 namespace,helm template 不会建 ns
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

# Step 1+2: 预拉所有镜像
prepull_helm_images monitoring prometheus-community/kube-prometheus-stack monitoring \
    -f "${CONTROL_DIR}/helm/monitoring/kps-values.yaml"

# Step 3: helm install
echo "===== Installing kube-prometheus-stack ====="
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f "${CONTROL_DIR}/helm/monitoring/kps-values.yaml" \
  --reuse-values=false \
  --wait --timeout 15m \
  || echo "⚠️  helm wait timeout (pod 大概率已 Running,继续)"

# Step 4: PV 权限(必须在 grafana StatefulSet 重启拉起来之前 chown 好)
chown_grafana_pv

# Step 5: 强删卡死 pod(给 controller 一次"用 cache 重建"的机会)
sleep 30
kick_stuck_pods monitoring
echo "    等 60 秒让 controller 重建..."
sleep 60
echo "    最终 monitoring 状态:"
kubectl get pods -n monitoring

# DCGM exporter
prepull_helm_images dcgm nvidia/dcgm-exporter monitoring \
    -f "${CONTROL_DIR}/helm/monitoring/dcgm/values.yaml"

echo "===== Installing DCGM exporter ====="
helm upgrade --install dcgm nvidia/dcgm-exporter \
  -n monitoring \
  -f "${CONTROL_DIR}/helm/monitoring/dcgm/values.yaml" \
  --reuse-values=false \
  --wait --timeout 5m \
  || echo "⚠️  DCGM helm wait timeout,继续(DaemonSet 在追)"

# ================================================================
# DCGM Grafana Dashboard 自动 import
# ================================================================
echo "===== Installing NVIDIA DCGM Grafana dashboard ====="
DCGM_DASHBOARD=/tmp/dcgm-dashboard.json
if curl -sfL "https://grafana.com/api/dashboards/12239/revisions/latest/download" -o "${DCGM_DASHBOARD}"; then
    DCGM_SIZE=$(wc -c < "${DCGM_DASHBOARD}" 2>/dev/null || echo 0)
    if [ "${DCGM_SIZE}" -ge 5000 ]; then
        sed -i 's|${DS_PROMETHEUS}|Prometheus|g' "${DCGM_DASHBOARD}"
        kubectl -n monitoring create configmap nvidia-dcgm-dashboard \
            --from-file=dcgm-dashboard.json="${DCGM_DASHBOARD}" \
            --dry-run=client -o yaml \
            | kubectl label --local -f - grafana_dashboard=1 -o yaml --dry-run=client \
            | kubectl apply -f -
        sleep 30
        GRAFANA_POD=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        [ -n "${GRAFANA_POD}" ] && kubectl exec -n monitoring "${GRAFANA_POD}" -c grafana -- killall -SIGHUP grafana 2>/dev/null || true
        echo "✓ DCGM dashboard 已 import"
    else
        echo "⚠️  DCGM dashboard 下载内容异常,跳过"
    fi
else
    echo "⚠️  无法从 grafana.com 下载 DCGM dashboard"
fi

# ================================================================
# HPA: metrics-server + prometheus-adapter
# 同样套路:先 prepull 再 helm install
# ================================================================
prepull_helm_images metrics-server metrics-server/metrics-server kube-system \
    --set 'args={--kubelet-insecure-tls,--kubelet-preferred-address-types=InternalIP}'

echo "===== Installing metrics-server (CPU/memory HPA) ====="
helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system \
  --set 'args={--kubelet-insecure-tls,--kubelet-preferred-address-types=InternalIP}' \
  --reuse-values=false \
  --wait --timeout 5m \
  || echo "⚠️  metrics-server helm timeout,继续"

prepull_helm_images prometheus-adapter prometheus-community/prometheus-adapter monitoring \
    -f "${CONTROL_DIR}/helm/monitoring/prometheus-adapter-values.yaml"

echo "===== Installing prometheus-adapter (custom metrics HPA) ====="
helm upgrade --install prometheus-adapter prometheus-community/prometheus-adapter \
  -n monitoring \
  -f "${CONTROL_DIR}/helm/monitoring/prometheus-adapter-values.yaml" \
  --reuse-values=false \
  --wait --timeout 5m \
  || echo "⚠️  prometheus-adapter helm timeout,继续"

# ================================================================
# Landing Page
# ================================================================
echo "===== Deploying Landing Page ====="
kubectl apply -f "${CONTROL_DIR}/llm/landing/landing-page-configmap.yaml"
kubectl apply -f "${CONTROL_DIR}/llm/landing/landing-nginx-deployment.yaml"
kubectl apply -f "${CONTROL_DIR}/llm/landing/landing-service.yaml"
kubectl apply -f "${CONTROL_DIR}/llm/landing/landing-ingress.yaml"
echo "✅ Landing Page deployed"

# ================================================================
# Final state
# ================================================================
echo ""
echo "===== Final cluster state ====="
kubectl get pods -A
echo ""
kubectl get nodes -o wide
echo ""

# 取 public IP (Lambda 通过 NAT,curl ifconfig.me 拿外部地址)
PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "<your-public-ip>")
PRIVATE_IP=$(ip -o -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')

echo "===== Access URLs (从你的笔记本访问,Lambda 必须开 :80 防火墙) ====="
echo ""
echo "  Public IP:   ${PUBLIC_IP}"
echo "  Private IP:  ${PRIVATE_IP}  (集群内部用)"
echo ""
echo "  Web UI:       http://${PUBLIC_IP}/web"
echo "  API:          http://${PUBLIC_IP}/api/v1/chat/completions"
echo "  Grafana:      http://${PUBLIC_IP}/grafana"
echo "  Prometheus:   http://${PUBLIC_IP}/prometheus"
echo "  ArgoCD:       http://${PUBLIC_IP}/argocd"
echo "  Landing:      http://${PUBLIC_IP}/"
echo ""
echo "===== ArgoCD 初始 admin 密码 ====="
echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d ; echo"
echo "  ⚠️  Lambda 是 public 网络,登入后立刻改强密码"
echo ""
echo "===== Verify monitoring is scraping ====="
echo "  Prometheus UI → Targets,应该看到全部 UP:"
echo "    - serviceMonitor/llm/llm-api/0"
echo "    - serviceMonitor/llm/vllm-worker/0"
echo "    - serviceMonitor/monitoring/dcgm-exporter/0"
echo ""
echo "🎉 Lambda A100 + ArgoCD + 监控栈 bootstrap DONE"
