#!/bin/bash
# =============================================================================
# Download Qwen2.5-0.5B-Instruct to the local model directory used by
# vllm-worker's hostPath mount.
#
# - Idempotent: skip if already downloaded
# - Use hf-mirror for speed (accessing huggingface.co from CN is slow)
# - Auto-install huggingface_hub (if not installed)
# - After download, perform sanity check to confirm required files exist
# =============================================================================

set -e

# ============ Configuration ============
MODEL_NAME="${MODEL_NAME:-Qwen/Qwen2.5-0.5B-Instruct}"
MODEL_LOCAL_NAME="${MODEL_LOCAL_NAME:-qwen2.5-0.5b}"
MODELS_ROOT="${MODELS_ROOT:-/home/johnny/Desktop/projects/llm-server/models}"
HF_ENDPOINT_URL="${HF_ENDPOINT:-https://hf-mirror.com}"

TARGET_DIR="${MODELS_ROOT}/${MODEL_LOCAL_NAME}"

# ============ Color output ============
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ============ 1. Check target directory ============
log_info "================================================"
log_info "Model:        ${MODEL_NAME}"
log_info "Local name:   ${MODEL_LOCAL_NAME}"
log_info "Target dir:   ${TARGET_DIR}"
log_info "HF endpoint:  ${HF_ENDPOINT_URL}"
log_info "================================================"
echo ""

mkdir -p "${TARGET_DIR}"

# Required files list (used for validation after download)
REQUIRED_FILES=(
    "config.json"
    "tokenizer.json"
    "tokenizer_config.json"
)

# ============ 2. Idempotency check ============
ALL_PRESENT=1
for f in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "${TARGET_DIR}/${f}" ]; then
        ALL_PRESENT=0
        break
    fi
done

# Also confirm model weights exist (safetensors / pytorch_model.bin / model.safetensors)
WEIGHTS_PRESENT=0
if ls "${TARGET_DIR}"/*.safetensors >/dev/null 2>&1 || \
   ls "${TARGET_DIR}"/pytorch_model.bin >/dev/null 2>&1; then
    WEIGHTS_PRESENT=1
fi

if [ "${ALL_PRESENT}" -eq 1 ] && [ "${WEIGHTS_PRESENT}" -eq 1 ]; then
    log_info "✅ Model already exists, skip download"
    log_info "To re-download, first delete: ${TARGET_DIR}"
    echo ""
    log_info "Existing files:"
    ls -lh "${TARGET_DIR}" | tail -n +2
    exit 0
fi

# ============ 3. Install huggingface_hub (if not installed) ============
log_info "Checking huggingface_hub..."
if ! python3 -c "import huggingface_hub" 2>/dev/null; then
    log_warn "huggingface_hub not installed, installing..."
    pip install --quiet -U "huggingface_hub"
fi

# Detect available CLI command:
#   - 1.13+ uses `hf`
#   - older uses `huggingface-cli` (deprecated but still works on some systems)
HF_CLI=""
if command -v hf >/dev/null 2>&1; then
    HF_CLI="hf"
elif command -v huggingface-cli >/dev/null 2>&1; then
    HF_CLI="huggingface-cli"
else
    log_error "Cannot find hf / huggingface-cli"
    log_error "Try: pip install -U huggingface_hub"
    exit 1
fi

log_info "huggingface_hub OK (using: ${HF_CLI})"
echo ""

# ============ 4. Download ============
log_info "Starting download (using ${HF_ENDPOINT_URL} mirror for speed)..."
log_info "0.5B model is ~1 GB, takes 1-3 minutes with good bandwidth"
echo ""

# Pass endpoint via env var (huggingface_hub reads it)
# Old and new CLI formats differ slightly, handle both
if [ "${HF_CLI}" = "hf" ]; then
    HF_ENDPOINT="${HF_ENDPOINT_URL}" hf download \
        "${MODEL_NAME}" \
        --local-dir "${TARGET_DIR}" \
        || {
            log_error "Download failed"
            log_error "Possible causes: network issue / mirror down / insufficient disk space"
            log_error "Try official source: HF_ENDPOINT=https://huggingface.co bash $0"
            exit 1
        }
else
    HF_ENDPOINT="${HF_ENDPOINT_URL}" huggingface-cli download \
        "${MODEL_NAME}" \
        --local-dir "${TARGET_DIR}" \
        --local-dir-use-symlinks False \
        || {
            log_error "Download failed"
            log_error "Possible causes: network issue / mirror down / insufficient disk space"
            log_error "Try official source: HF_ENDPOINT=https://huggingface.co bash $0"
            exit 1
        }
fi

echo ""
log_info "Download complete, verifying files..."

# ============ 5. Verification ============
MISSING=()
for f in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "${TARGET_DIR}/${f}" ]; then
        MISSING+=("${f}")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    log_error "Download complete but missing required files: ${MISSING[*]}"
    log_error "Please check ${TARGET_DIR}"
    exit 1
fi

if ! ls "${TARGET_DIR}"/*.safetensors >/dev/null 2>&1 && \
   ! ls "${TARGET_DIR}"/pytorch_model.bin >/dev/null 2>&1; then
    log_error "Download complete but missing model weights (.safetensors / pytorch_model.bin)"
    exit 1
fi

# ============ 6. Summary ============
TOTAL_SIZE=$(du -sh "${TARGET_DIR}" | awk '{print $1}')

echo ""
log_info "================================================"
log_info "✅ Model download complete"
log_info "================================================"
log_info "Location: ${TARGET_DIR}"
log_info "Size:     ${TOTAL_SIZE}"
log_info "Files:    $(find "${TARGET_DIR}" -type f | wc -l)"
echo ""
log_info "vllm-worker will mount this to /model/${MODEL_LOCAL_NAME} in the pod"
log_info "Next step: sudo bash script/laptop/launch.sh"
