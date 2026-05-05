#!/bin/bash
# =====================================================================
# Lambda Labs A100 — node bootstrap (all_install.sh)
# ---------------------------------------------------------------------
# Installation script for GCP_BRANCH on **Lambda Labs A100 bare metal**.
# Lambda base image comes pre-installed with:
#   - NVIDIA driver (580.x)
#   - containerd
#   - docker
#   - nvidia-container-toolkit (nvidia-ctk)
#
# So we **do not** repeat installing these components. We only install what Lambda is missing:
#   - kubelet / kubeadm / kubectl
#   - helm
# Plus some **mandatory aligned** configurations:
#   - swap off                              (k8s requirement)
#   - containerd SystemdCgroup = true       (k8s requirement; default cgroupfs causes
#                                            kubelet/control-plane crash loop — same
#                                            issue as laptop, see MEMORY)
#   - MIG status self-check                 (warn-only)
#
# Differences from script/laptop/all_install.sh:
#   - No GPU detection branch — this machine always has A100
#   - Do not install nvidia-container-toolkit — Lambda already has it
#   - Do not install docker — Lambda already has it
#   - Do not install containerd — Lambda already has it (but modify cgroup driver)
#   - Add MIG self-check — A100 uses 7× 1g.5gb hardware partitions
#
# Usage:
#   sudo bash script/lambda/all_install.sh
# =====================================================================
set -e
echo "===== Lambda A100 node initialization (all_install.sh) ====="

##############################################
# 1. Disable swap
# ----------------------------------------------------------------
# kubelet refuses nodes with swap enabled. Lambda base image usually
# has swap off, but run idempotently to ensure.
##############################################
echo "[1/6] Disable swap"
if [ "$(swapon --show | wc -l)" -gt 0 ]; then
    sudo swapoff -a
    sudo sed -i '/ swap / s/^/#/' /etc/fstab
    echo "  ✓ swap disabled"
else
    echo "  ➡ swap already disabled, skip"
fi

##############################################
# 1.5. Common utilities (jq, bc) — test suite dependencies
# ----------------------------------------------------------------
# Lambda base image does not include jq/bc. test/run_lambda.sh and
# troubleshooting commands need them; install once. curl/awk/git usually present.
##############################################
echo "[2/6] Install common utilities (jq, bc)"
NEED_INSTALL=()
command -v jq >/dev/null 2>&1 || NEED_INSTALL+=(jq)
command -v bc >/dev/null 2>&1 || NEED_INSTALL+=(bc)

if [ ${#NEED_INSTALL[@]} -gt 0 ]; then
    sudo apt-get update -y
    sudo apt-get install -y "${NEED_INSTALL[@]}"
    echo "  ✓ Installed: ${NEED_INSTALL[*]}"
else
    echo "  ➡ jq / bc already present, skip"
fi

##############################################
# 2. Install Kubernetes trio (kubelet / kubeadm / kubectl)
# ----------------------------------------------------------------
# Lambda does not install these by default. Version lock v1.30
# (consistent with laptop branch; manifests use v1.30 + autoscaling/v2).
##############################################
echo "[3/6] Install kubelet / kubeadm / kubectl (v1.30)"
if ! command -v kubeadm >/dev/null 2>&1; then
    sudo mkdir -p /etc/apt/keyrings

    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key \
        | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/k8s.gpg

    echo "deb [signed-by=/etc/apt/keyrings/k8s.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" \
        | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

    sudo apt-get update -y
    sudo apt-get install -y kubelet kubeadm kubectl
    sudo apt-mark hold kubelet kubeadm kubectl
    echo "  ✓ kubeadm/kubelet/kubectl installed: $(kubeadm version -o short)"
else
    echo "  ➡ kubeadm already present, skip (version: $(kubeadm version -o short))"
fi

##############################################
# 3. Align containerd cgroup driver (k8s requires systemd)
# ----------------------------------------------------------------
# ⚠️ This step is **mandatory**.
# Lambda base image containerd defaults to cgroupfs cgroup driver,
# but k8s v1.30 requires systemd — mismatch causes:
#   - kubelet continuous SIGTERM restart
#   - control plane (etcd / apiserver) enters CrashLoopBackOff
#   - kubeadm init hangs at "waiting for control plane to be healthy"
# Hit the same issue on laptop; enforce SystemdCgroup=true here.
#
# Order matters: this step writes only SystemdCgroup; nvidia runtime injection
# left for launch.sh Phase 2.5 (nvidia-ctk runtime configure needs incremental
# changes on a config with SystemdCgroup=true already).
##############################################
echo "[4/6] Align containerd cgroup driver = systemd"
if ! command -v containerd >/dev/null 2>&1; then
    echo "  ⚠️  containerd not installed — Lambda image should have it, check system"
    exit 1
fi

sudo systemctl enable containerd >/dev/null 2>&1 || true
sudo mkdir -p /etc/containerd

if [ ! -f /etc/containerd/config.toml ] || ! grep -q "SystemdCgroup = true" /etc/containerd/config.toml 2>/dev/null; then
    echo "  ➡ /etc/containerd/config.toml is not SystemdCgroup=true, regenerating"
    containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    sudo systemctl restart containerd
    echo "  ✓ Wrote SystemdCgroup=true and restarted containerd"
else
    echo "  ✓ /etc/containerd/config.toml already has SystemdCgroup=true, keep"
fi

##############################################
# 4. Helm
# ----------------------------------------------------------------
# kube-prometheus-stack / argocd-image-updater / argo-cd are all
# installed via helm charts, so helm is required.
##############################################
echo "[5/6] Install Helm"
if ! command -v helm >/dev/null 2>&1; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    echo "  ✓ Helm installed: $(helm version --short)"
else
    echo "  ➡ Helm already present, skip ($(helm version --short))"
fi

##############################################
# 5. Auto-configure MIG (7× 1g.5gb)
# ----------------------------------------------------------------
# A100 uses 7× 1g.5gb MIG instances for hardware isolation, the core
# point of GCP_BRANCH narrative ("laptop software time-slicing → A100 hardware MIG").
#
# Fully automatic:
#   1. If MIG mode not enabled → enable it
#   2. If instance count is not 7 → clean up remnants + recreate 7
#   3. profile ID queried dynamically (may vary by driver version, not hardcoded to 19)
#
# Idempotent: running N times yields the same result; if 7 instances exist, skip creation.
#
# ⚠️ Prerequisite: no CUDA processes on GPU, else -mig 1 fails.
# Lambda bare metal usually fine at boot.
##############################################
echo "[6/6] Auto-configure MIG (7× 1g.5gb)"

if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "  ⚠️  nvidia-smi not found — Lambda image should have driver, check system"
    exit 1
fi

# ---- 5.1 Enable MIG mode ----
MIG_MODE=$(nvidia-smi -i 0 --query-gpu=mig.mode.current --format=csv,noheader 2>/dev/null | tr -d ' ')
echo "  ➡ Current MIG mode = ${MIG_MODE}"

if [ "$MIG_MODE" != "Enabled" ]; then
    echo "  ➡ MIG not enabled, enabling..."
    if sudo nvidia-smi -i 0 -mig 1; then
        echo "  ✓ MIG mode enabled"
    else
        echo "  ⚠️  nvidia-smi -mig 1 failed"
        echo "      Most common cause: CUDA processes still running on GPU"
        echo "      Check: nvidia-smi   (see if Processes table is empty)"
        echo "      If processes exist: kill them and re-run this script"
        echo "      If no processes and still fails: usually needs machine restart"
        exit 1
    fi
fi

# ---- 5.2 Count current instances ----
MIG_INSTANCES=$(nvidia-smi -L 2>/dev/null | grep -c "MIG" || true)
echo "  ➡ Current MIG instance count = ${MIG_INSTANCES}"

if [ "$MIG_INSTANCES" -eq 7 ]; then
    echo "  ✓ Already have 7 MIG instances, skip creation"
else
    # ---- 5.3 Clean up residual instances (if any) ----
    if [ "$MIG_INSTANCES" -gt 0 ]; then
        echo "  ➡ Have ${MIG_INSTANCES} incomplete instances, destroying all CI + GI"
        # Order matters: must destroy CI first, then GI
        sudo nvidia-smi mig -dci 2>/dev/null || true
        sudo nvidia-smi mig -dgi 2>/dev/null || true
    fi

    # ---- 5.4 Dynamically query 1g.5gb profile ID ----
    # nvidia-smi mig -lgip output format:
    #   |   0  MIG 1g.5gb        19     7/7        4864 MB    No  ...
    # 5th column (left to right, excluding |) is profile ID.
    PROFILE_ID=$(nvidia-smi mig -lgip 2>/dev/null \
                  | grep -E "MIG[[:space:]]+1g\.5gb" \
                  | head -1 \
                  | awk '{print $5}')

    if [ -z "$PROFILE_ID" ]; then
        echo "  ⚠️  Cannot find 1g.5gb profile, this GPU may not support it"
        echo "      Available profiles:"
        nvidia-smi mig -lgip
        exit 1
    fi
    echo "  ➡ 1g.5gb profile ID = ${PROFILE_ID}"

    # ---- 5.5 Create 7× GI + CI (one command, -C auto-creates CI) ----
    echo "  ➡ Creating 7× 1g.5gb GI+CI..."
    sudo nvidia-smi mig -cgi \
        "${PROFILE_ID},${PROFILE_ID},${PROFILE_ID},${PROFILE_ID},${PROFILE_ID},${PROFILE_ID},${PROFILE_ID}" \
        -C

    # ---- 5.6 Verify ----
    FINAL_COUNT=$(nvidia-smi -L 2>/dev/null | grep -c "MIG" || true)
    if [ "$FINAL_COUNT" -eq 7 ]; then
        echo "  ✓ 7 MIG instances created successfully"
    else
        echo "  ⚠️  Actually created ${FINAL_COUNT} instances (expected 7), check:"
        nvidia-smi -L
        exit 1
    fi
fi

echo ""
echo "===== Lambda A100 all_install.sh complete ====="
echo ""
echo "Final MIG status confirmation:"
nvidia-smi -L | grep MIG || echo "  (empty — abnormal, review log above)"
echo ""
echo "Next step: sudo bash script/lambda/launch.sh"
