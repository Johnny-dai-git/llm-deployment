#!/bin/bash
# =====================================================================
# Lambda Labs A100 — node bootstrap (all_install.sh)
# ---------------------------------------------------------------------
# 这是 GCP_BRANCH 在 **Lambda Labs A100 裸机** 上的安装脚本。
# Lambda 的 base image 已经预装:
#   - NVIDIA driver (580.x)
#   - containerd
#   - docker
#   - nvidia-container-toolkit (nvidia-ctk)
#
# 所以这里 **不再** 重复安装这些组件。我们只做 Lambda 没装的:
#   - kubelet / kubeadm / kubectl
#   - helm
# 加上一些 **必须强制对齐** 的配置:
#   - swap off                              (k8s 强制要求)
#   - containerd SystemdCgroup = true       (k8s 强制要求,默认 cgroupfs 会
#                                            导致 kubelet/control-plane
#                                            crash loop —— 跟 laptop 那次
#                                            一样,见 MEMORY)
#   - MIG 状态自检                           (warn-only)
#
# 与 script/laptop/all_install.sh 的区别:
#   - 不做 GPU 检测分支 —— 这台机器永远有 A100
#   - 不装 nvidia-container-toolkit —— Lambda 已经装了
#   - 不装 docker —— Lambda 已经装了
#   - 不装 containerd —— Lambda 已经装了 (但要改 cgroup driver)
#   - 加 MIG 自检 —— A100 用 7× 1g.5gb 硬件分区
#
# 运行方式:
#   sudo bash script/lambda/all_install.sh
# =====================================================================
set -e
echo "===== Lambda A100 节点初始化 (all_install.sh) ====="

##############################################
# 1. 禁用 swap
# ----------------------------------------------------------------
# kubelet 启动会拒绝有 swap 的节点。Lambda base image 一般 swap 已经关,
# 但 idempotent 跑一次确保。
##############################################
echo "[1/6] 禁用 swap"
if [ "$(swapon --show | wc -l)" -gt 0 ]; then
    sudo swapoff -a
    sudo sed -i '/ swap / s/^/#/' /etc/fstab
    echo "  ✓ swap 已关闭"
else
    echo "  ➡ swap 已经是关闭状态,跳过"
fi

##############################################
# 1.5. 通用工具 (jq, bc) — test 套件依赖
# ----------------------------------------------------------------
# Lambda base image 不带 jq / bc。test/run_lambda.sh + 故障诊断
# 命令都需要,先一次性装好。curl / awk / git 通常已经在了。
##############################################
echo "[2/6] 安装通用工具 (jq, bc)"
NEED_INSTALL=()
command -v jq >/dev/null 2>&1 || NEED_INSTALL+=(jq)
command -v bc >/dev/null 2>&1 || NEED_INSTALL+=(bc)

if [ ${#NEED_INSTALL[@]} -gt 0 ]; then
    sudo apt-get update -y
    sudo apt-get install -y "${NEED_INSTALL[@]}"
    echo "  ✓ 已安装: ${NEED_INSTALL[*]}"
else
    echo "  ➡ jq / bc 已存在,跳过"
fi

##############################################
# 2. 安装 Kubernetes 三件套 (kubelet / kubeadm / kubectl)
# ----------------------------------------------------------------
# Lambda 默认不装这些。版本锁 v1.30(跟 laptop 分支一致,
# manifest 都是按 v1.30 + autoscaling/v2 写的)。
##############################################
echo "[3/6] 安装 kubelet / kubeadm / kubectl (v1.30)"
if ! command -v kubeadm >/dev/null 2>&1; then
    sudo mkdir -p /etc/apt/keyrings

    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key \
        | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/k8s.gpg

    echo "deb [signed-by=/etc/apt/keyrings/k8s.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" \
        | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

    sudo apt-get update -y
    sudo apt-get install -y kubelet kubeadm kubectl
    sudo apt-mark hold kubelet kubeadm kubectl
    echo "  ✓ kubeadm/kubelet/kubectl 已安装: $(kubeadm version -o short)"
else
    echo "  ➡ kubeadm 已存在,跳过 (version: $(kubeadm version -o short))"
fi

##############################################
# 3. containerd cgroup driver 对齐 (k8s 必须 systemd)
# ----------------------------------------------------------------
# ⚠️ 这一步是 **不能省** 的。
# Lambda base image 的 containerd 默认 cgroup driver 是 cgroupfs,
# 但 k8s v1.30 要求 systemd —— 不一致会导致:
#   - kubelet 不停 SIGTERM 重启
#   - control plane (etcd / apiserver) 进 CrashLoopBackOff
#   - kubeadm init 卡死在 "waiting for control plane to be healthy"
# 笔记本那次踩过同一个坑,这里强制写 SystemdCgroup=true。
#
# 顺序很重要:这一步只写 SystemdCgroup,nvidia runtime 注入留给
# launch.sh Phase 2.5 (因为 nvidia-ctk runtime configure 需要在
# 已经有 SystemdCgroup=true 的 config 上做增量修改)。
##############################################
echo "[4/6] 校准 containerd cgroup driver = systemd"
if ! command -v containerd >/dev/null 2>&1; then
    echo "  ⚠️  containerd 未安装 —— Lambda image 应该自带,请检查系统"
    exit 1
fi

sudo systemctl enable containerd >/dev/null 2>&1 || true
sudo mkdir -p /etc/containerd

if [ ! -f /etc/containerd/config.toml ] || ! grep -q "SystemdCgroup = true" /etc/containerd/config.toml 2>/dev/null; then
    echo "  ➡ /etc/containerd/config.toml 不是 SystemdCgroup=true,重新生成"
    containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    sudo systemctl restart containerd
    echo "  ✓ 已写入 SystemdCgroup=true 并重启 containerd"
else
    echo "  ✓ /etc/containerd/config.toml 已是 SystemdCgroup=true,保留"
fi

##############################################
# 4. Helm
# ----------------------------------------------------------------
# kube-prometheus-stack / argocd-image-updater / argo-cd 都是 helm chart
# 装的,所以 helm 必须有。
##############################################
echo "[5/6] 安装 Helm"
if ! command -v helm >/dev/null 2>&1; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    echo "  ✓ Helm 已安装: $(helm version --short)"
else
    echo "  ➡ Helm 已存在,跳过 ($(helm version --short))"
fi

##############################################
# 5. 自动配置 MIG (7× 1g.5gb)
# ----------------------------------------------------------------
# A100 用 7× 1g.5gb MIG 实例做硬件隔离,这是 GCP_BRANCH 简历叙事
# 的核心点 ("laptop 软件 time-slicing → A100 硬件 MIG")。
#
# 这一步全自动:
#   1. 如果 MIG 模式没开 → 自动开
#   2. 如果实例数不是 7 → 清掉残留 + 重新创建 7 个
#   3. profile ID 动态查询 (不同 driver 版本可能不同,不写死 19)
#
# 幂等性:跑 N 次结果一样,已经 7 个实例就跳过。
#
# ⚠️ 前置条件:GPU 上不能有 CUDA 进程在跑,否则 -mig 1 会失败。
# Lambda 裸机刚开机时一般没问题。
##############################################
echo "[6/6] 自动配置 MIG (7× 1g.5gb)"

if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "  ⚠️  nvidia-smi 不存在 —— Lambda image 应该自带 driver,请检查"
    exit 1
fi

# ---- 5.1 启用 MIG 模式 ----
MIG_MODE=$(nvidia-smi -i 0 --query-gpu=mig.mode.current --format=csv,noheader 2>/dev/null | tr -d ' ')
echo "  ➡ 当前 MIG mode = ${MIG_MODE}"

if [ "$MIG_MODE" != "Enabled" ]; then
    echo "  ➡ MIG 未启用,正在启用..."
    if sudo nvidia-smi -i 0 -mig 1; then
        echo "  ✓ MIG 模式已启用"
    else
        echo "  ⚠️  nvidia-smi -mig 1 失败"
        echo "      最常见原因:GPU 上还有 CUDA 进程在跑"
        echo "      检查: nvidia-smi   (看 Processes 表是不是空)"
        echo "      如果有进程: 杀掉后重跑这个脚本"
        echo "      如果没有进程仍失败: 通常需要重启机器再试"
        exit 1
    fi
fi

# ---- 5.2 计算当前实例数 ----
MIG_INSTANCES=$(nvidia-smi -L 2>/dev/null | grep -c "MIG" || true)
echo "  ➡ 当前 MIG 实例数 = ${MIG_INSTANCES}"

if [ "$MIG_INSTANCES" -eq 7 ]; then
    echo "  ✓ 已有 7 个 MIG 实例,跳过创建"
else
    # ---- 5.3 清理残留实例 (如果有) ----
    if [ "$MIG_INSTANCES" -gt 0 ]; then
        echo "  ➡ 有 ${MIG_INSTANCES} 个不完整实例,先销毁所有 CI + GI"
        # 顺序很重要:必须先销毁 CI,再销毁 GI
        sudo nvidia-smi mig -dci 2>/dev/null || true
        sudo nvidia-smi mig -dgi 2>/dev/null || true
    fi

    # ---- 5.4 动态查 1g.5gb 的 profile ID ----
    # nvidia-smi mig -lgip 的输出格式:
    #   |   0  MIG 1g.5gb        19     7/7        4864 MB    No  ...
    # 第 5 列 (从左数,排除 |) 是 profile ID。
    PROFILE_ID=$(nvidia-smi mig -lgip 2>/dev/null \
                  | grep -E "MIG[[:space:]]+1g\.5gb" \
                  | head -1 \
                  | awk '{print $5}')

    if [ -z "$PROFILE_ID" ]; then
        echo "  ⚠️  找不到 1g.5gb profile,这张 GPU 可能不支持"
        echo "      可用 profile:"
        nvidia-smi mig -lgip
        exit 1
    fi
    echo "  ➡ 1g.5gb profile ID = ${PROFILE_ID}"

    # ---- 5.5 创建 7 个 GI + CI (一条命令,-C 自动建 CI) ----
    echo "  ➡ 创建 7 个 1g.5gb GI+CI..."
    sudo nvidia-smi mig -cgi \
        "${PROFILE_ID},${PROFILE_ID},${PROFILE_ID},${PROFILE_ID},${PROFILE_ID},${PROFILE_ID},${PROFILE_ID}" \
        -C

    # ---- 5.6 验证 ----
    FINAL_COUNT=$(nvidia-smi -L 2>/dev/null | grep -c "MIG" || true)
    if [ "$FINAL_COUNT" -eq 7 ]; then
        echo "  ✓ 7 个 MIG 实例创建成功"
    else
        echo "  ⚠️  实际创建 ${FINAL_COUNT} 个实例 (期望 7),请检查:"
        nvidia-smi -L
        exit 1
    fi
fi

echo ""
echo "===== Lambda A100 all_install.sh 执行完毕 ====="
echo ""
echo "MIG 状态最终确认:"
nvidia-smi -L | grep MIG || echo "  (空 — 异常,请回看上面日志)"
echo ""
echo "下一步: sudo bash script/lambda/launch.sh"
