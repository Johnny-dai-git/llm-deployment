#!/bin/bash
set -e

# ======= Configuration (can be overridden by environment variables) =======
GITHUB_USERNAME="${GITHUB_USERNAME:-Johnny-dai-git}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_REPO="${GITHUB_REPO:-llm-deployment}"
# Default to telemetry branch (development mainline), can switch back to main after stable
GITHUB_BRANCH="${GITHUB_BRANCH:-telemetry}"

# Storage device: use /dev/sda4 on desktop/server, fallback to project dir on laptops without this partition
# Fallback path: script adds /k8s layer, so final PV lands at
#   /home/johnny/Desktop/projects/llm-server/data/k8s
# Benefits: same directory tree as project code, survives reboot, easy backup/migration, no IO contention with etcd/containerd
STORAGE_DEVICE="${STORAGE_DEVICE:-/dev/sda4}"
STORAGE_FALLBACK_PATH="${STORAGE_FALLBACK_PATH:-/home/johnny/Desktop/projects/llm-server/data}"

if [ -n "${GITHUB_TOKEN}" ]; then
  GITHUB_URL="https://${GITHUB_TOKEN}@github.com/${GITHUB_USERNAME}/${GITHUB_REPO}.git"
else
  GITHUB_URL="https://github.com/${GITHUB_USERNAME}/${GITHUB_REPO}.git"
  echo "⚠️  GITHUB_TOKEN not set, using git credential helper"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# launch.sh is now in script/laptop/, repo root is one level up
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
INSTALL_DIR="${SCRIPT_DIR}"
CONTROL_DIR="${REPO_DIR}/tools"

# GPU detection (global, reused by subsequent phases)
HAS_GPU=0
if lspci 2>/dev/null | grep -i nvidia >/dev/null 2>&1; then
  HAS_GPU=1
fi

echo "===== Kubernetes control-plane bootstrap start ====="
echo ">>> Branch:    ${GITHUB_BRANCH}"
echo ">>> Has GPU:   $([ $HAS_GPU -eq 1 ] && echo yes || echo no)"
echo ">>> Storage:   ${STORAGE_DEVICE} (fallback to ${STORAGE_FALLBACK_PATH} if not found)"
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
# Phase 2.5: align containerd config
# ----------------------------------------------------------------
# This step resolves two tangled gotchas, order matters:
#
# Gotcha 1 — inconsistent cgroup driver (required fix):
#   Ubuntu defaults to cgroup v2 + kubeadm kubelet cgroupDriver=systemd,
#   but containerd with compiled-in defaults (no /etc/containerd/config.toml)
#   defaults to SystemdCgroup=false using cgroupfs. Mismatch → kubelet fails
#   to start static pods (etcd/apiserver/controller-manager/scheduler start
#   ~14s then SIGTERM, crash loop).
#   Fix: generate default config.toml and set all SystemdCgroup to true.
#
# Gotcha 2 — missing nvidia runtime handler (GPU nodes required):
#   Generating default config erases runtimes.nvidia block injected by
#   nvidia-container-toolkit. Result: pods with RuntimeClass 'nvidia'
#   (vllm-worker / dcgm-exporter) hang at ContainerCreating with error:
#     "no runtime for 'nvidia' is configured"
#   Fix: use nvidia-ctk to inject nvidia runtime back into containerd config.
#   nvidia-ctk may set SystemdCgroup=false in new nvidia block, so do final
#   sed 'true' as fallback.
#
# Must run before system.sh (kubeadm init), otherwise control plane crashes.
# ================================================================
echo ">>> Phase 2.5: align containerd config (cgroup + nvidia runtime)"
sudo mkdir -p /etc/containerd
NEED_RESTART_CONTAINERD=0

# (1) Ensure SystemdCgroup = true
if [ ! -f /etc/containerd/config.toml ] || ! grep -q "SystemdCgroup = true" /etc/containerd/config.toml 2>/dev/null; then
    echo "    - Generate default containerd config and enable SystemdCgroup"
    sudo containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    NEED_RESTART_CONTAINERD=1
else
    echo "    ✔ containerd already has SystemdCgroup=true"
fi

# (2) GPU nodes: inject nvidia runtime handler into containerd config
if [ "${HAS_GPU}" -eq 1 ]; then
    if command -v nvidia-ctk >/dev/null 2>&1; then
        if ! grep -q 'runtimes\.nvidia' /etc/containerd/config.toml 2>/dev/null; then
            echo "    - Inject nvidia runtime handler using nvidia-ctk"
            sudo nvidia-ctk runtime configure --runtime=containerd --config=/etc/containerd/config.toml
            # nvidia-ctk may set SystemdCgroup=false in new block, fix it back to true
            sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
            NEED_RESTART_CONTAINERD=1
        else
            echo "    ✔ containerd already has nvidia runtime handler"
        fi
    else
        echo "    ⚠️  HAS_GPU=1 but nvidia-ctk not found, RuntimeClass 'nvidia' pods will hang"
        echo "       Please confirm all_install.sh installed nvidia-container-toolkit"
    fi
fi

# (3) Need restart for config to take effect
if [ "${NEED_RESTART_CONTAINERD}" -eq 1 ]; then
    echo "    - Restart containerd to apply config"
    sudo systemctl restart containerd
    for i in $(seq 1 10); do
        [ -S /run/containerd/containerd.sock ] && break
        sleep 1
    done
fi
echo "    ✔ Phase 2.5 complete"

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
    echo "⚠️  vllm-worker requires nvidia.com/gpu, will be Pending without GPU on this node"
fi

# ================================================================
# Phase 4: infra + GPU (install only when GPU exists)
# ================================================================
if [ "${HAS_GPU}" -eq 1 ]; then
    echo ">>> Installing NVIDIA device plugin..."
    kubectl apply -f "${CONTROL_DIR}/system/nvidia-device-plugin.yaml" || true
    kubectl rollout status ds/nvidia-device-plugin-daemonset -n kube-system --timeout=60s || true

    # RuntimeClass
    kubectl get runtimeclass nvidia >/dev/null 2>&1 || \
    kubectl apply -f "${CONTROL_DIR}/system/runtimeclass-nvidia.yaml"
else
    echo ">>> No GPU, skip NVIDIA device plugin and RuntimeClass"
fi

# ================================================================
# Storage (local-path)
# Prefer partition specified by STORAGE_DEVICE, fallback to local dir if not found
# ================================================================
MOUNT_POINT=""
if [ -b "${STORAGE_DEVICE}" ]; then
    MOUNT_POINT=$(findmnt -n -o TARGET "${STORAGE_DEVICE}" 2>/dev/null || true)
    [ -z "${MOUNT_POINT}" ] && \
      MOUNT_POINT=$(lsblk -n -o MOUNTPOINT "${STORAGE_DEVICE}" 2>/dev/null | head -1)
fi

if [ -z "${MOUNT_POINT}" ]; then
    echo "⚠️  ${STORAGE_DEVICE} not mounted or doesn't exist, fallback to ${STORAGE_FALLBACK_PATH}"
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
# ArgoCD Image Updater (managed via hand-written YAML)
# ================================================================
echo "===== Installing ArgoCD Image Updater ====="

# 0. Ensure namespace
kubectl get ns argocd || kubectl create ns argocd

# 1. Create ServiceAccount (required)
echo ">>> Step 1: Creating ServiceAccount..."
kubectl apply -f "${CONTROL_DIR}/argocd-image-updater/argocd-image-updater-sa.yaml"

# Verify ServiceAccount
kubectl get sa -n argocd | grep argocd-image-updater || echo "⚠️  ServiceAccount not found"

# 2. Apply RBAC (ClusterRole + Binding)
echo ">>> Step 2: Applying RBAC..."
kubectl apply -f "${CONTROL_DIR}/argocd-image-updater/argocd-image-updater-clusterrole.yaml"
kubectl apply -f "${CONTROL_DIR}/argocd-image-updater/argocd-image-updater-clusterrolebinding.yaml"

# Immediately verify permissions (critical step)
echo ">>> Verifying RBAC permissions..."
if kubectl auth can-i list applications.argoproj.io \
  --as system:serviceaccount:argocd:argocd-image-updater 2>/dev/null | grep -q "yes"; then
  echo "✅ RBAC permissions verified"
else
  echo "⚠️  RBAC permissions check failed, but continuing..."
fi

# 3. Create ConfigMap (core Image Updater config)
echo ">>> Step 3: Creating ConfigMap..."
kubectl apply -f "${CONTROL_DIR}/argocd-image-updater/argocd-image-updater-config.yaml"

# Verify ConfigMap
kubectl get cm -n argocd | grep image-updater || echo "⚠️  ConfigMap not found"

# 4. Create ServiceAccount Token (recommended for K8s ≥1.24)
echo ">>> Step 4: Creating ServiceAccount Token..."
kubectl apply -f "${CONTROL_DIR}/argocd-image-updater/argocd-image-updater-token.yaml" || true

# 5. Start Image Updater Deployment
echo ">>> Step 5: Starting Image Updater Deployment..."
kubectl apply -f "${CONTROL_DIR}/argocd-image-updater/argocd-image-updater-controller.yaml"

# Wait for Deployment readiness
echo ">>> Waiting for Image Updater to be ready..."
kubectl rollout status deployment/argocd-image-updater-controller -n argocd --timeout=5m || echo "⚠️  Deployment may still be starting..."

# ================================================================
# ArgoCD Applications (Image Updater needs these Applications to work)
# ================================================================
echo "===== Deploying ArgoCD Applications ====="

# Deploy LLM Platform Services Application
echo ">>> Deploying llm-platform-services Application..."
kubectl apply -f "${CONTROL_DIR}/argocd-image-updater/llm-application.yaml"

# Wait for Application creation to complete
echo ">>> Waiting for Application to be created..."
sleep 5
kubectl get application llm-platform-services -n argocd || echo "⚠️  Application not found"

echo "✅ ArgoCD Applications deployed"

# ================================================================
# Monitoring (kube-prometheus-stack + DCGM)
# --reuse-values=false: ensure kps-values.yaml changes take effect
# ================================================================

# ----------------------------------------------------------------
# Apply PriorityClass first (kps helm values reference it, if helm
# installed first then PriorityClass applied, helm will complain)
# See priority-classes.yaml with two tiers:
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

# Install DCGM only when GPU exists
if [ "${HAS_GPU}" -eq 1 ]; then
    echo "===== Installing DCGM exporter ====="
    helm upgrade --install dcgm nvidia/dcgm-exporter \
      -n monitoring \
      -f "${CONTROL_DIR}/helm/monitoring/dcgm/values.yaml" \
      --reuse-values=false \
      --wait --timeout 5m
else
    echo ">>> No GPU, skip DCGM exporter"
fi

# ================================================================
# NVIDIA DCGM Grafana Dashboard auto-import (GPU nodes only)
# ----------------------------------------------------------------
# Approach:
#   kube-prometheus-stack includes grafana-sc-dashboard sidecar,
#   it automatically converts all ConfigMaps with label `grafana_dashboard=1`
#   to dashboards written to /tmp/dashboards/. We download NVIDIA official
#   dashboard 12239 JSON, put it in ConfigMap, sidecar manages it.
#
# Not using Grafana admin API (requires password, 401 in anonymous admin mode).
# Not using helm values (changing kps requires helm upgrade, expensive).
# This approach is idempotent, no errors on repeated runs.
# ================================================================
if [ "${HAS_GPU}" -eq 1 ]; then
    echo "===== Installing NVIDIA DCGM Grafana dashboard ====="
    DCGM_DASHBOARD=/tmp/dcgm-dashboard.json

    # Download NVIDIA official DCGM Exporter Dashboard (id=12239) latest revision
    if curl -sfL "https://grafana.com/api/dashboards/12239/revisions/latest/download" -o "${DCGM_DASHBOARD}"; then
        DCGM_SIZE=$(wc -c < "${DCGM_DASHBOARD}" 2>/dev/null || echo 0)
        if [ "${DCGM_SIZE}" -lt 5000 ]; then
            echo "⚠️  DCGM dashboard download anomaly (size=${DCGM_SIZE} < 5KB), skip"
        else
            # Replace datasource placeholder with actual datasource name (kube-prometheus-stack defaults to 'Prometheus')
            sed -i 's|${DS_PROMETHEUS}|Prometheus|g' "${DCGM_DASHBOARD}"

            # Create ConfigMap with grafana_dashboard=1 label, sidecar auto-loads
            kubectl -n monitoring create configmap nvidia-dcgm-dashboard \
                --from-file=dcgm-dashboard.json="${DCGM_DASHBOARD}" \
                --dry-run=client -o yaml \
                | kubectl label --local -f - grafana_dashboard=1 -o yaml --dry-run=client \
                | kubectl apply -f -

            # Wait for sidecar to write file to grafana container
            sleep 30

            # Make Grafana re-scan provisioning directory (SIGHUP triggers reload)
            GRAFANA_POD=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
            if [ -n "${GRAFANA_POD}" ]; then
                kubectl exec -n monitoring "${GRAFANA_POD}" -c grafana -- killall -SIGHUP grafana 2>/dev/null || true
                echo "✓ DCGM dashboard imported, search 'nvidia' or 'dcgm' in Grafana to view"
            else
                echo "⚠️  Grafana pod not found, dashboard file written to ConfigMap, auto-loads when Grafana starts"
            fi
        fi
    else
        echo "⚠️  Cannot download DCGM dashboard from grafana.com (network or URL issue), skip"
    fi
fi

# ================================================================
# HPA support: metrics-server + prometheus-adapter
# ================================================================
# metrics-server: provides K8s resource metrics (CPU/memory), required for HPA Resource type
# --kubelet-insecure-tls needed on kubeadm clusters with self-signed certs, use proper cert in prod
echo "===== Installing metrics-server (for CPU/memory HPA) ====="
helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system \
  --set 'args={--kubelet-insecure-tls,--kubelet-preferred-address-types=InternalIP}' \
  --reuse-values=false \
  --wait --timeout 5m

# prometheus-adapter: convert any Prometheus metric to K8s custom metrics API
# Enable HPA based on business metrics like vllm:num_requests_waiting
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
echo "===== Access URLs (hostNetwork=true, directly bind to laptop port 80) ====="
echo "  Web UI:       http://localhost/web"
echo "  API:          http://localhost/api/v1/chat/completions"
echo "  Grafana:      http://localhost/grafana   (anonymous Admin access enabled)"
echo "  Prometheus:   http://localhost/prometheus"
echo "  Landing:      http://localhost/"
echo ""
echo "===== Verify monitoring is actually scraping ====="
echo "  Check targets page in Prometheus UI, should see:"
echo "    - serviceMonitor/llm/llm-api/0   (UP)"
echo "    - serviceMonitor/llm/vllm-worker/0 (UP)"
if [ "${HAS_GPU}" -eq 1 ]; then
    echo "    - serviceMonitor/monitoring/dcgm-exporter/0 (UP)"
fi
echo ""

if [ "${HAS_GPU}" -eq 0 ]; then
    echo "⚠️  No GPU on this node, vllm-worker will stay Pending:"
    echo "    nodeSelector gpu-node=true has no matching nodes, nvidia.com/gpu: 1 cannot be satisfied"
    echo "    To run vllm-worker, must deploy on node with NVIDIA GPU"
    echo ""
fi

echo "🎉 Kubernetes + ArgoCD + Image Updater bootstrap DONE"
