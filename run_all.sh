echo "Start"
sleep 20
echo "20 seconds passed"
#!/bin/bash
set -e

# ======= 配置区域（只需改这里） =======
REMOTE_USER="exouser"

CONTROL_IP="149.165.150.232"     # control 节点
SYSTEM_NODES=("149.165.147.30")  # system 节点
GPU_NODES=("149.165.147.25" "149.165.147.81")  # GPU worker 节点

# GitHub repository configuration
GITHUB_USERNAME="Johnny-dai-git"
GITHUB_TOKEN="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"
GITHUB_REPO="llm-deployment"
GITHUB_BRANCH="main"
GITHUB_URL="https://${GITHUB_TOKEN}@github.com/${GITHUB_USERNAME}/${GITHUB_REPO}.git"

REMOTE_HOME="/home/${REMOTE_USER}"
REMOTE_REPO_DIR="${REMOTE_HOME}/llm-deployment"
REMOTE_INSTALL_DIR="${REMOTE_REPO_DIR}/install"

SSH_KEY="$HOME/.ssh/id_ed25519.pub"

ALL_NODES=("$CONTROL_IP" "${SYSTEM_NODES[@]}" "${GPU_NODES[@]}")

# ================================================================
# Phase 0: 自动 ssh-copy-id（一次性写入公钥）
# ================================================================
echo "===== Phase 0: 将 SSH 公钥自动分发到所有节点（如已存在会自动跳过） ====="

if [ ! -f "$SSH_KEY" ]; then
  echo "❌ 找不到 SSH 公钥: $SSH_KEY"
  exit 1
fi

for IP in "${ALL_NODES[@]}"; do
  echo ">>> [SSH] 检查节点 $IP 是否已免密访问..."

  if ssh -o PasswordAuthentication=no -o BatchMode=yes ${REMOTE_USER}@${IP} "echo ok" 2>/dev/null; then
    echo "✔ $IP 已免密，无需 ssh-copy-id"
  else
    echo "⚠ $IP 尚未免密，需要一次输入密码写入公钥"
    ssh-copy-id -i "$SSH_KEY" "${REMOTE_USER}@${IP}"
  fi
done

# ================================================================
# Phase 0.5: 确保所有节点已安装 git
# ================================================================
echo
echo "===== Phase 0.5: 确保所有节点已安装 git ====="

for IP in "${ALL_NODES[@]}"; do
  echo ">>> [git] 检查节点 $IP 是否已安装 git..."
  ssh ${REMOTE_USER}@${IP} "which git || (sudo apt update && sudo apt install -y git)"
done

# ================================================================
# Phase 1: 在所有节点上 clone GitHub 仓库
# ================================================================
echo
echo "===== Phase 1: 在所有节点上 clone GitHub 仓库 ====="

SYSTEM_NODE_IP=${SYSTEM_NODES[0]}

for IP in "${ALL_NODES[@]}"; do
  echo ">>> [Git] 在节点 $IP 上 clone 仓库..."
  
  ssh ${REMOTE_USER}@${IP} << EOF
    cd ${REMOTE_HOME}
    if [ -d "${REMOTE_REPO_DIR}" ]; then
      echo "  Repository already exists, pulling latest changes..."
      cd ${REMOTE_REPO_DIR}
      git pull origin ${GITHUB_BRANCH} || echo "⚠ Git pull failed, continuing..."
    else
      echo "  Cloning repository..."
      git clone -b ${GITHUB_BRANCH} ${GITHUB_URL} ${REMOTE_REPO_DIR}
    fi
EOF

  # 修改 metallb-ip-pool.yaml，使用 system node IP（仅在 control 节点）
  if [ "$IP" == "$CONTROL_IP" ]; then
    echo ">>> 修改 metallb-ip-pool.yaml 使用 system node IP: $SYSTEM_NODE_IP ..."
    ssh ${REMOTE_USER}@${IP} "cd ${REMOTE_REPO_DIR} && \
      sed -i 's/PUBLIC_IP/${SYSTEM_NODE_IP}/' control/config/k8s/base/metallb/metallb-ip-pool.yaml && \
      echo '✔ Modified metallb-ip-pool.yaml'"
  fi
done

# ================================================================
# Phase 2: 所有节点执行 all_install.sh
# ================================================================
echo
echo "===== Phase 2: 所有节点执行 all_install.sh（通用初始化）====="

for IP in "${ALL_NODES[@]}"; do
  echo ">>> [all_install] 在 $IP 上执行 ..."
  ssh ${REMOTE_USER}@${IP} "cd ${REMOTE_INSTALL_DIR} && sudo bash all_install.sh"
done

# ================================================================
# Phase 3: control 节点执行 control.sh
# ================================================================
echo
echo "===== Phase 3: control 节点初始化 kubeadm + CNI ====="

# 在执行 control.sh 之前，先修改它以添加 --node-name=control
echo ">>> 修改 control.sh 以设置 node-name=control ..."
ssh ${REMOTE_USER}@${CONTROL_IP} "cd ${REMOTE_INSTALL_DIR} && \
  sudo sed -i 's/kubeadm init --pod-network-cidr=/kubeadm init --node-name=control --pod-network-cidr=/' control.sh"

# 执行 control.sh
ssh ${REMOTE_USER}@${CONTROL_IP} "cd ${REMOTE_INSTALL_DIR} && sudo bash control.sh"

# ================================================================
# Phase 4: 获取 join 命令
# ================================================================
echo
echo "===== Phase 4: 自动从 control 节点获取 kubeadm join 命令 ====="
JOIN_CMD=$(ssh ${REMOTE_USER}@${CONTROL_IP} "sudo kubeadm token create --print-join-command")

if [ -z "$JOIN_CMD" ]; then
  echo "❌ 无法获取 join 命令，退出"
  exit 1
fi

echo "✔ 获取到 JOIN_CMD:"
echo "   $JOIN_CMD"

# ================================================================
# Phase 5: system / GPU 节点做初始化（不 join）
# ================================================================
echo
echo "===== Phase 5: 各类节点执行本地初始化脚本 ====="

# system 节点
for IP in "${SYSTEM_NODES[@]}"; do
  echo ">>> [system] 在 $IP 上执行 system.sh ..."
  ssh ${REMOTE_USER}@${IP} "cd ${REMOTE_INSTALL_DIR} && sudo bash system.sh"
done

# gpu 节点
for IP in "${GPU_NODES[@]}"; do
  echo ">>> [gpu worker] 在 $IP 上执行 gpu_worker.sh ..."
  ssh ${REMOTE_USER}@${IP} "cd ${REMOTE_INSTALL_DIR} && sudo bash gpu_worker.sh"
done

# ================================================================
# Phase 6: 统一 join 所有非-control 节点
# ================================================================
echo
echo "===== Phase 6: 所有 worker 节点执行 kubeadm join ====="

# system 节点 join，使用 node-name=system
for IP in "${SYSTEM_NODES[@]}"; do
  echo ">>> [join] $IP 加入集群 (node-name=system) ..."
  ssh ${REMOTE_USER}@${IP} "sudo $JOIN_CMD --node-name=system"
done

# GPU 节点 join，使用 node-name=worker-1, worker-2
GPU_INDEX=1
for IP in "${GPU_NODES[@]}"; do
  NODE_NAME="worker-${GPU_INDEX}"
  echo ">>> [join] $IP 加入集群 (node-name=$NODE_NAME) ..."
  ssh ${REMOTE_USER}@${IP} "sudo $JOIN_CMD --node-name=$NODE_NAME"
  GPU_INDEX=$((GPU_INDEX + 1))
done

echo
echo "🎉🎉🎉 全部节点已经加入 Kubernetes 集群！"
echo "👉 回到 control 节点运行："
echo "     ssh ${REMOTE_USER}@${CONTROL_IP}"
echo "     cd ${REMOTE_REPO_DIR}/control"
echo "     bash run_control"
echo ""
echo "如果你需要下一步部署 vLLM / Triton / Dynamo，我也可以帮你一键化！"

echo
echo "===== Phase 7: 为所有节点自动打开新的 terminal 并 SSH 登录 ====="

open_terminal_cmd="gnome-terminal -- bash -c"

# 打开 control 节点终端
echo ">>> 打开 control 节点终端：${CONTROL_IP}"
$open_terminal_cmd "ssh ${REMOTE_USER}@${CONTROL_IP}; exec bash" &

# 打开 system 节点终端
for IP in "${SYSTEM_NODES[@]}"; do
  echo ">>> 打开 system 节点终端：$IP"
  $open_terminal_cmd "ssh ${REMOTE_USER}@${IP}; exec bash" &
done

# 打开 GPU worker 节点终端
for IP in "${GPU_NODES[@]}"; do
  echo ">>> 打开 GPU worker 节点终端：$IP"
  $open_terminal_cmd "ssh ${REMOTE_USER}@${IP}; exec bash" &
done

echo "===== 所有节点的终端已打开！====="
