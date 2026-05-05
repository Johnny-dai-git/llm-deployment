#!/bin/bash
# =====================================================================
# Lambda Labs A100 — one-shot bootstrap (launch.sh)
# ---------------------------------------------------------------------
# Differences from script/laptop/launch.sh:
#   - Remove HAS_GPU detection branch — Lambda is always a GPU node
#   - STORAGE_FALLBACK_PATH: /mnt/k8s (not /home/johnny/...)
#   - Call script/lambda/all_install.sh + system.sh (this directory)
#   - Final ACCESS URLs use public IP (161.153.48.3) not localhost
#
# Before running, ensure:
#   1. all_install.sh already run (7 MIG instances configured)
#   2. script/lambda/download-model.sh already run (/mnt/models/qwen2.5-0.5b)
#   3. Lambda firewall opened on port 80
# =====================================================================
set -e

# ======= Config area (can override with environment variables) =======
GITHUB_USERNAME="${GITHUB_USERNAME:-Johnny-dai-git}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_REPO="${GITHUB_REPO:-llm-deployment}"
# Lambda uses GCP_BRANCH
GITHUB_BRANCH="${GITHUB_BRANCH:-GCP_BRANCH}"

# Lambda doesn't have /dev/sda4 disks, just fallback to /mnt/k8s
STORAGE_DEVICE="${STORAGE_DEVICE:-/dev/none}"
STORAGE_FALLBACK_PATH="${STORAGE_FALLBACK_PATH:-/mnt/k8s}"

if [ -n "${GITHUB_TOKEN}" ]; then
  GITHUB_URL="https://${GITHUB_TOKEN}@github.com/${GITHUB_USERNAME}/${GITHUB_REPO}.git"
else
  GITHUB_URL="https://github.com/${GITHUB_USERNAME}/${GITHUB_REPO}.git"
  echo "⚠️  GITHUB_TOKEN not set, using git credential helper"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# launch.sh lives in script/lambda/, repo root is two levels up
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
# Phase 2: common install (k8s + helm + MIG config)
# ================================================================
cd "${INSTALL_DIR}"
sudo bash all_install.sh

# ================================================================
# Phase 2.5: containerd config alignment (cgroup + nvidia runtime + docker.io mirror)
# ----------------------------------------------------------------
# all_install.sh already wrote SystemdCgroup; now do two more things:
#
#   (a) Inject nvidia runtime handler
#       nvidia-ctk runtime configure writes SystemdCgroup=false in the new nvidia block
#       → must sed it again
#
#   (b) Add docker.io registry mirror
#       Lambda egress IP pulling docker.io often throttled, causing helper pod /
#       grafana images to hang in ContainerCreating. Using mirror.gcr.io
#       (Google-maintained docker hub mirror) rarely stalls. After multiple incidents,
#       added to default config.
#
# Must complete before system.sh (kubeadm init), else control plane crashes on startup.
# ================================================================
echo ">>> Phase 2.5: Align containerd (nvidia runtime + docker.io mirror)"
NEED_RESTART_CONTAINERD=0

# (a) nvidia runtime
if command -v nvidia-ctk >/dev/null 2>&1; then
    if ! grep -q 'runtimes\.nvidia' /etc/containerd/config.toml 2>/dev/null; then
        echo "    - Inject nvidia runtime handler with nvidia-ctk"
        sudo nvidia-ctk runtime configure --runtime=containerd --config=/etc/containerd/config.toml
        sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
        NEED_RESTART_CONTAINERD=1
    else
        echo "    ✔ containerd already has nvidia runtime handler"
    fi
else
    echo "    ⚠️  nvidia-ctk not found, pods with RuntimeClass 'nvidia' will hang"
    exit 1
fi

# (b) docker.io mirror (Lambda pulling docker hub often hangs)
if ! grep -q 'mirrors\."docker.io"' /etc/containerd/config.toml 2>/dev/null; then
    echo "    - Add docker.io mirror → mirror.gcr.io"
    # Insert docker.io mirror block after [plugins."io.containerd.grpc.v1.cri".registry.mirrors] line.
    # If that anchor line doesn't exist (old containerd config), append full block to file end.
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
    echo "    ✔ containerd already has docker.io mirror"
fi

if [ "${NEED_RESTART_CONTAINERD}" -eq 1 ]; then
    echo "    - Restart containerd for config to take effect"
    sudo systemctl restart containerd
    for i in $(seq 1 10); do
        [ -S /run/containerd/containerd.sock ] && break
        sleep 1
    done
fi
echo "    ✔ Phase 2.5 complete"

# ================================================================
# Phase 2.6: Common helper functions (used for all helm installs later)
# ----------------------------------------------------------------
# Hit "kubelet image pull hang" issue 3 times on Lambda; root cause is
# kubelet internal pull state machine sometimes wedges, hangs even if image
# local. Solution: use crictl to pull directly to containerd cache, then
# forcefully delete hung pod to let ReplicaSet/StatefulSet rebuild, which
# will cache-hit instantly.
#
# These functions standardize the pattern; call before/after any helm install.
# ================================================================

# Use helm template to extract all images after chart render, then crictl pull once.
# Usage: prepull_helm_images <release> <chart> <namespace> [extra args...]
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
        echo "    (helm template produced no images, skip)"
        return 0
    fi

    while read -r img; do
        [ -z "$img" ] && continue
        echo "    -> $img"
        sudo crictl pull "$img" >/dev/null 2>&1 || echo "       ⚠️  pull failed (kubelet will retry)"
    done <<< "$images"
}

# Forcefully delete all non-Running pods in namespace, let controller rebuild.
# Usage: kick_stuck_pods <namespace>
kick_stuck_pods() {
    local namespace="$1"
    echo ">>> Force-delete stuck pods in ${namespace} (let controller rebuild with cache)..."
    local stuck
    stuck=$(kubectl get pods -n "${namespace}" --no-headers 2>/dev/null \
            | awk '$3 != "Running" && $3 != "Completed" {print $1}')
    if [ -z "$stuck" ]; then
        echo "    (no stuck pods)"
        return 0
    fi
    while read -r pod; do
        [ -z "$pod" ] && continue
        echo "    force-delete $pod"
        kubectl delete pod -n "${namespace}" "$pod" --force --grace-period=0 2>/dev/null || true
    done <<< "$stuck"
}

# Chown Grafana local-path PV to UID 472.
# Necessary: kps-values.yaml disabled init-chown-data (modern chart uses non-root;
# chown on hostPath PV hits Permission denied), so launch.sh does it on host.
# fsGroup ineffective on hostPath.
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
        echo "    ⚠️  PVC not bound yet, skip chown (grafana may not start)"
        return 1
    fi
    hostpath=$(kubectl get pv "$pv" -o jsonpath='{.spec.hostPath.path}' 2>/dev/null || true)
    if [ -z "$hostpath" ]; then
        echo "    ⚠️  PV ${pv} has no hostPath, skip"
        return 1
    fi
    echo "    PV host path: $hostpath"
    sudo chown -R 472:472 "$hostpath"
    sudo chmod -R 775 "$hostpath"
    echo "    ✔ chown complete"
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
echo ">>> Install NVIDIA device plugin (MIG single strategy → 7 nvidia.com/gpu)"
kubectl apply -f "${CONTROL_DIR}/system/nvidia-device-plugin.yaml" || true
kubectl rollout status ds/nvidia-device-plugin-daemonset -n kube-system --timeout=120s || true

# RuntimeClass
kubectl get runtimeclass nvidia >/dev/null 2>&1 || \
kubectl apply -f "${CONTROL_DIR}/system/runtimeclass-nvidia.yaml"

# Verify MIG instances seen by k8s
echo ">>> Verify nvidia.com/gpu resource count (should = 7):"
kubectl get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}{"\n"}' || echo "(not yet visible; wait and check kubectl describe node)"

# ================================================================
# Storage (local-path)
# Lambda has no dedicated STORAGE_DEVICE partition, fallback to /mnt/k8s
# ================================================================
MOUNT_POINT=""
if [ -b "${STORAGE_DEVICE}" ]; then
    MOUNT_POINT=$(findmnt -n -o TARGET "${STORAGE_DEVICE}" 2>/dev/null || true)
    [ -z "${MOUNT_POINT}" ] && \
      MOUNT_POINT=$(lsblk -n -o MOUNTPOINT "${STORAGE_DEVICE}" 2>/dev/null | head -1)
fi

if [ -z "${MOUNT_POINT}" ]; then
    echo "ℹ️  ${STORAGE_DEVICE} not found, using fallback ${STORAGE_FALLBACK_PATH}"
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
# hostNetwork=true → bind directly to host :80, accessible via Lambda public IP
# Also use prepull pattern to avoid webhook-certgen job pull hanging and blocking controller
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
  || echo "⚠️  ArgoCD helm timeout, continue (controller catching up)"

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
    echo "⚠️  Image Updater still starting..."

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
# Monitoring stack is most prone to image pull issues (grafana / kiwigrid on docker.io;
# often hangs minutes on Lambda). Process changed to:
#   1. helm template extract all images
#   2. crictl pre-pull to containerd cache (via mirror.gcr.io)
#   3. helm install
#   4. immediately chown grafana PV after install (kps-values.yaml disabled init-chown-data)
#   5. forcefully delete any stuck pods (let controller rebuild; cache hit instant)
# ================================================================
echo "===== Applying PriorityClasses for monitoring stack ====="
kubectl apply -f "${CONTROL_DIR}/helm/monitoring/priority-classes.yaml"

# Must create namespace first; helm template won't create ns
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

# Step 1+2: Pre-pull all images
prepull_helm_images monitoring prometheus-community/kube-prometheus-stack monitoring \
    -f "${CONTROL_DIR}/helm/monitoring/kps-values.yaml"

# Step 3: helm install
echo "===== Installing kube-prometheus-stack ====="
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f "${CONTROL_DIR}/helm/monitoring/kps-values.yaml" \
  --reuse-values=false \
  --wait --timeout 15m \
  || echo "⚠️  helm wait timeout (pods likely already Running, continue)"

# Step 4: PV permissions (must chown before grafana StatefulSet restarts and comes up)
chown_grafana_pv

# Step 5: Force-delete stuck pods (give controller one "rebuild with cache" chance)
sleep 30
kick_stuck_pods monitoring
echo "    waiting 60 sec for controller to rebuild..."
sleep 60
echo "    final monitoring state:"
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
  || echo "⚠️  DCGM helm wait timeout, continue (DaemonSet catching up)"

# ================================================================
# Grafana Dashboards auto-import
# ----------------------------------------------------------------
# Use grafana-sc-dashboard sidecar pattern: any ConfigMap labeled
# `grafana_dashboard=1` auto-converted by sidecar to dashboard written to
# /tmp/dashboards/. Install two:
#
#   1. Upstream NVIDIA DCGM Exporter Dashboard (id 12239)
#      — generic full-card metrics view. In MIG environment, most panels show
#      "GPU 0" 7 rows (legend uses {{gpu}} label only), so auxiliary only.
#
#   2. Custom "Lambda A100 / MIG / vLLM" dashboard
#      — designed for GCP_BRANCH: per-MIG compute / Tensor Core /
#      VRAM, and MIG↔Pod mapping table. Legend uses {{GPU_I_ID}} +
#      {{pod}}; 7 MIG instances clearly distinguished.
# ================================================================
echo "===== Installing Grafana dashboards (DCGM upstream + custom MIG) ====="

# ---- Dashboard 1: Upstream DCGM (12239) ----
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
        echo "    ✓ NVIDIA DCGM (12239) ConfigMap applied"
    else
        echo "    ⚠️  DCGM dashboard download content anomalous, skip"
    fi
else
    echo "    ⚠️  unable to download DCGM dashboard from grafana.com, skip"
fi

# ---- Dashboard 2: Custom Lambda A100 / MIG / vLLM ----
MIG_DASHBOARD="${CONTROL_DIR}/helm/monitoring/dashboards/mig-vllm-dashboard.json"
if [ -f "${MIG_DASHBOARD}" ]; then
    kubectl -n monitoring create configmap mig-vllm-dashboard \
        --from-file=mig-vllm-dashboard.json="${MIG_DASHBOARD}" \
        --dry-run=client -o yaml \
        | kubectl label --local -f - grafana_dashboard=1 -o yaml --dry-run=client \
        | kubectl apply -f -
    echo "    ✓ Lambda A100 / MIG / vLLM ConfigMap applied"
else
    echo "    ⚠️  custom MIG dashboard not found (${MIG_DASHBOARD}), skip"
fi

# ---- Let sidecar convert new ConfigMap to dashboard ----
sleep 30
GRAFANA_POD=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "${GRAFANA_POD}" ]; then
    # SIGHUP tells grafana to re-read provisioning; sidecar writes file + grafana reload = instantly visible
    kubectl exec -n monitoring "${GRAFANA_POD}" -c grafana -- killall -SIGHUP grafana 2>/dev/null || true
    echo "    ✓ Grafana SIGHUP'd — should see two new dashboards in left Dashboards menu"
fi

# ================================================================
# HPA: metrics-server + prometheus-adapter
# Same pattern: prepull first, then helm install
# ================================================================
prepull_helm_images metrics-server metrics-server/metrics-server kube-system \
    --set 'args={--kubelet-insecure-tls,--kubelet-preferred-address-types=InternalIP}'

echo "===== Installing metrics-server (CPU/memory HPA) ====="
helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system \
  --set 'args={--kubelet-insecure-tls,--kubelet-preferred-address-types=InternalIP}' \
  --reuse-values=false \
  --wait --timeout 5m \
  || echo "⚠️  metrics-server helm timeout, continue"

prepull_helm_images prometheus-adapter prometheus-community/prometheus-adapter monitoring \
    -f "${CONTROL_DIR}/helm/monitoring/prometheus-adapter-values.yaml"

echo "===== Installing prometheus-adapter (custom metrics HPA) ====="
helm upgrade --install prometheus-adapter prometheus-community/prometheus-adapter \
  -n monitoring \
  -f "${CONTROL_DIR}/helm/monitoring/prometheus-adapter-values.yaml" \
  --reuse-values=false \
  --wait --timeout 5m \
  || echo "⚠️  prometheus-adapter helm timeout, continue"

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

# Get public IP (Lambda via NAT; curl ifconfig.me for external address)
PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "<your-public-ip>")
PRIVATE_IP=$(ip -o -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')

echo "===== Access URLs (from your laptop; Lambda must allow :80 in firewall) ====="
echo ""
echo "  Public IP:   ${PUBLIC_IP}"
echo "  Private IP:  ${PRIVATE_IP}  (for cluster-internal use)"
echo ""
echo "  Web UI:       http://${PUBLIC_IP}/web"
echo "  API:          http://${PUBLIC_IP}/api/v1/chat/completions"
echo "  Grafana:      http://${PUBLIC_IP}/grafana"
echo "  Prometheus:   http://${PUBLIC_IP}/prometheus"
echo "  ArgoCD:       http://${PUBLIC_IP}/argocd"
echo "  Landing:      http://${PUBLIC_IP}/"
echo ""
echo "===== ArgoCD initial admin password ====="
echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d ; echo"
echo "  ⚠️  Lambda is on public network; change to strong password immediately after login"
echo ""
echo "===== Verify monitoring is scraping ====="
echo "  Prometheus UI → Targets, should see all UP:"
echo "    - serviceMonitor/llm/llm-api/0"
echo "    - serviceMonitor/llm/vllm-worker/0"
echo "    - serviceMonitor/monitoring/dcgm-exporter/0"
echo ""
echo "🎉 Lambda A100 + ArgoCD + monitoring stack bootstrap DONE"
