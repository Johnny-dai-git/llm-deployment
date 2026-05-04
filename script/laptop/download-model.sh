#!/bin/bash
# =============================================================================
# Download Qwen2.5-0.5B-Instruct to the local model directory used by
# vllm-worker's hostPath mount.
#
# - 幂等:已下载好就 skip
# - 用 hf-mirror 加速(国内访问 huggingface.co 速度差)
# - 自动装 huggingface_hub(如未装)
# - 下载完后做 sanity check,确认必需文件存在
# =============================================================================

set -e

# ============ 配置 ============
MODEL_NAME="${MODEL_NAME:-Qwen/Qwen2.5-0.5B-Instruct}"
MODEL_LOCAL_NAME="${MODEL_LOCAL_NAME:-qwen2.5-0.5b}"
MODELS_ROOT="${MODELS_ROOT:-/home/johnny/Desktop/projects/llm-server/models}"
HF_ENDPOINT_URL="${HF_ENDPOINT:-https://hf-mirror.com}"

TARGET_DIR="${MODELS_ROOT}/${MODEL_LOCAL_NAME}"

# ============ 颜色输出 ============
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ============ 1. 检查目标目录 ============
log_info "================================================"
log_info "Model:        ${MODEL_NAME}"
log_info "Local name:   ${MODEL_LOCAL_NAME}"
log_info "Target dir:   ${TARGET_DIR}"
log_info "HF endpoint:  ${HF_ENDPOINT_URL}"
log_info "================================================"
echo ""

mkdir -p "${TARGET_DIR}"

# 必需文件清单(下完后用来校验)
REQUIRED_FILES=(
    "config.json"
    "tokenizer.json"
    "tokenizer_config.json"
)

# ============ 2. 幂等检查 ============
ALL_PRESENT=1
for f in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "${TARGET_DIR}/${f}" ]; then
        ALL_PRESENT=0
        break
    fi
done

# 还要确认有模型权重(safetensors / pytorch_model.bin / model.safetensors)
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

# ============ 3. 装 huggingface_hub(如未装) ============
log_info "Checking huggingface_hub..."
if ! python3 -c "import huggingface_hub" 2>/dev/null; then
    log_warn "huggingface_hub 未安装,正在安装..."
    pip install --quiet -U "huggingface_hub"
fi

# 检测可用的 CLI 命令:
#   - 1.13+ 用 `hf`
#   - 老版用 `huggingface-cli`(已 deprecated 但部分老环境还能跑)
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

# ============ 4. 下载 ============
log_info "开始下载(用 ${HF_ENDPOINT_URL} 镜像加速)..."
log_info "0.5B 模型大小约 1 GB,带宽好的话 1-3 分钟"
echo ""

# 用环境变量传 endpoint(huggingface_hub 会读)
# 新旧 CLI 命令格式略有差异,统一处理
if [ "${HF_CLI}" = "hf" ]; then
    HF_ENDPOINT="${HF_ENDPOINT_URL}" hf download \
        "${MODEL_NAME}" \
        --local-dir "${TARGET_DIR}" \
        || {
            log_error "下载失败"
            log_error "可能原因: 网络问题 / 镜像源挂了 / 磁盘空间不足"
            log_error "换官方源试试: HF_ENDPOINT=https://huggingface.co bash $0"
            exit 1
        }
else
    HF_ENDPOINT="${HF_ENDPOINT_URL}" huggingface-cli download \
        "${MODEL_NAME}" \
        --local-dir "${TARGET_DIR}" \
        --local-dir-use-symlinks False \
        || {
            log_error "下载失败"
            log_error "可能原因: 网络问题 / 镜像源挂了 / 磁盘空间不足"
            log_error "换官方源试试: HF_ENDPOINT=https://huggingface.co bash $0"
            exit 1
        }
fi

echo ""
log_info "下载完成,验证文件..."

# ============ 5. 校验 ============
MISSING=()
for f in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "${TARGET_DIR}/${f}" ]; then
        MISSING+=("${f}")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    log_error "下载完成但缺少必需文件: ${MISSING[*]}"
    log_error "请检查 ${TARGET_DIR}"
    exit 1
fi

if ! ls "${TARGET_DIR}"/*.safetensors >/dev/null 2>&1 && \
   ! ls "${TARGET_DIR}"/pytorch_model.bin >/dev/null 2>&1; then
    log_error "下载完成但没有模型权重文件 (.safetensors / pytorch_model.bin)"
    exit 1
fi

# ============ 6. 总结 ============
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
log_info "下一步: sudo bash script/laptop/launch.sh"
