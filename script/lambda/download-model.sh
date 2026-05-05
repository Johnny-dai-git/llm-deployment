#!/bin/bash
# =============================================================================
# Lambda A100 — 下载 Qwen2.5-0.5B-Instruct 到 vllm-worker 的 hostPath 挂载点
#
# 与 laptop 版本的差异:
#   - MODELS_ROOT: /mnt/models (而不是 /home/johnny/.../models)
#     —— 与 GCP_BRANCH manifests 里 hostPath: /mnt/models 对齐
#   - HF endpoint: 默认官方 huggingface.co (Lambda 在美国,不需要镜像)
#
# 幂等:已下载好就 skip。
# =============================================================================

set -e

# ============ 配置 ============
MODEL_NAME="${MODEL_NAME:-Qwen/Qwen2.5-0.5B-Instruct}"
MODEL_LOCAL_NAME="${MODEL_LOCAL_NAME:-qwen2.5-0.5b}"
MODELS_ROOT="${MODELS_ROOT:-/mnt/models}"
HF_ENDPOINT_URL="${HF_ENDPOINT:-https://huggingface.co}"

TARGET_DIR="${MODELS_ROOT}/${MODEL_LOCAL_NAME}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

log_info "================================================"
log_info "Model:        ${MODEL_NAME}"
log_info "Local name:   ${MODEL_LOCAL_NAME}"
log_info "Target dir:   ${TARGET_DIR}"
log_info "HF endpoint:  ${HF_ENDPOINT_URL}"
log_info "================================================"
echo ""

# 创建目录(如果是 root 跑)
sudo mkdir -p "${TARGET_DIR}"
sudo chmod 755 "${MODELS_ROOT}"
# 让当前用户能写
if [ -n "${SUDO_USER:-}" ]; then
    sudo chown -R "${SUDO_USER}:${SUDO_USER}" "${TARGET_DIR}"
fi

REQUIRED_FILES=(
    "config.json"
    "tokenizer.json"
    "tokenizer_config.json"
)

# 幂等检查
ALL_PRESENT=1
for f in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "${TARGET_DIR}/${f}" ]; then
        ALL_PRESENT=0
        break
    fi
done

WEIGHTS_PRESENT=0
if ls "${TARGET_DIR}"/*.safetensors >/dev/null 2>&1 || \
   ls "${TARGET_DIR}"/pytorch_model.bin >/dev/null 2>&1; then
    WEIGHTS_PRESENT=1
fi

if [ "${ALL_PRESENT}" -eq 1 ] && [ "${WEIGHTS_PRESENT}" -eq 1 ]; then
    log_info "✅ 模型已存在,跳过下载"
    log_info "如要重下,先删除: ${TARGET_DIR}"
    echo ""
    log_info "已有文件清单:"
    ls -lh "${TARGET_DIR}" | tail -n +2
    exit 0
fi

# 装 huggingface_hub
log_info "Checking huggingface_hub..."
if ! python3 -c "import huggingface_hub" 2>/dev/null; then
    log_warn "huggingface_hub 未安装,正在安装..."
    pip install --quiet -U "huggingface_hub" || pip install --quiet --break-system-packages -U "huggingface_hub"
fi

HF_CLI=""
if command -v hf >/dev/null 2>&1; then
    HF_CLI="hf"
elif command -v huggingface-cli >/dev/null 2>&1; then
    HF_CLI="huggingface-cli"
else
    log_error "找不到 hf / huggingface-cli"
    log_error "尝试: pip install -U huggingface_hub"
    exit 1
fi

log_info "huggingface_hub OK (using: ${HF_CLI})"
echo ""

log_info "开始下载..."
log_info "0.5B 模型大小约 1 GB,Lambda 内网带宽很快,十几秒搞定"
echo ""

if [ "${HF_CLI}" = "hf" ]; then
    HF_ENDPOINT="${HF_ENDPOINT_URL}" hf download \
        "${MODEL_NAME}" \
        --local-dir "${TARGET_DIR}" \
        || {
            log_error "下载失败"
            log_error "可能原因: 网络问题 / hf token 缺失 / 磁盘空间不足"
            exit 1
        }
else
    HF_ENDPOINT="${HF_ENDPOINT_URL}" huggingface-cli download \
        "${MODEL_NAME}" \
        --local-dir "${TARGET_DIR}" \
        --local-dir-use-symlinks False \
        || {
            log_error "下载失败"
            exit 1
        }
fi

echo ""
log_info "下载完成,验证文件..."

MISSING=()
for f in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "${TARGET_DIR}/${f}" ]; then
        MISSING+=("${f}")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    log_error "下载完成但缺少必需文件: ${MISSING[*]}"
    exit 1
fi

if ! ls "${TARGET_DIR}"/*.safetensors >/dev/null 2>&1 && \
   ! ls "${TARGET_DIR}"/pytorch_model.bin >/dev/null 2>&1; then
    log_error "下载完成但没有模型权重文件"
    exit 1
fi

TOTAL_SIZE=$(du -sh "${TARGET_DIR}" | awk '{print $1}')

echo ""
log_info "================================================"
log_info "✅ 模型下载完成"
log_info "================================================"
log_info "位置:    ${TARGET_DIR}"
log_info "大小:    ${TOTAL_SIZE}"
log_info "文件数:  $(find "${TARGET_DIR}" -type f | wc -l)"
echo ""
log_info "vllm-worker 会从这里挂载到 Pod 内 /model/${MODEL_LOCAL_NAME}"
log_info "下一步: sudo bash script/lambda/launch.sh"
