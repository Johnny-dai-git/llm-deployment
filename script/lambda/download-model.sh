#!/bin/bash
# =============================================================================
# Lambda A100 — download Qwen2.5-0.5B-Instruct to vllm-worker's hostPath mount
#
# Differences from laptop version:
#   - MODELS_ROOT: /mnt/models (not /home/johnny/.../models)
#     — aligns with hostPath: /mnt/models in GCP_BRANCH manifests
#   - HF endpoint: default official huggingface.co (Lambda in US, no mirror needed)
#
# Idempotent: if already downloaded, skip.
# =============================================================================

set -e

# ============ Configuration ============
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

# Create directory (if running as root)
sudo mkdir -p "${TARGET_DIR}"
sudo chmod 755 "${MODELS_ROOT}"
# Allow current user to write
if [ -n "${SUDO_USER:-}" ]; then
    sudo chown -R "${SUDO_USER}:${SUDO_USER}" "${TARGET_DIR}"
fi

REQUIRED_FILES=(
    "config.json"
    "tokenizer.json"
    "tokenizer_config.json"
)

# Idempotent check
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
    log_info "✅ Model already exists, skip download"
    log_info "To re-download, first delete: ${TARGET_DIR}"
    echo ""
    log_info "Existing files:"
    ls -lh "${TARGET_DIR}" | tail -n +2
    exit 0
fi

# Install huggingface_hub
log_info "Checking huggingface_hub..."
if ! python3 -c "import huggingface_hub" 2>/dev/null; then
    log_warn "huggingface_hub not installed, installing..."
    pip install --quiet -U "huggingface_hub" || pip install --quiet --break-system-packages -U "huggingface_hub"
fi

HF_CLI=""
if command -v hf >/dev/null 2>&1; then
    HF_CLI="hf"
elif command -v huggingface-cli >/dev/null 2>&1; then
    HF_CLI="huggingface-cli"
else
    log_error "cannot find hf / huggingface-cli"
    log_error "try: pip install -U huggingface_hub"
    exit 1
fi

log_info "huggingface_hub OK (using: ${HF_CLI})"
echo ""

log_info "Starting download..."
log_info "0.5B model is ~1 GB; Lambda internal bandwidth is fast, should take ~10 seconds"
echo ""

if [ "${HF_CLI}" = "hf" ]; then
    HF_ENDPOINT="${HF_ENDPOINT_URL}" hf download \
        "${MODEL_NAME}" \
        --local-dir "${TARGET_DIR}" \
        || {
            log_error "Download failed"
            log_error "Possible causes: network issue / missing hf token / insufficient disk space"
            exit 1
        }
else
    HF_ENDPOINT="${HF_ENDPOINT_URL}" huggingface-cli download \
        "${MODEL_NAME}" \
        --local-dir "${TARGET_DIR}" \
        --local-dir-use-symlinks False \
        || {
            log_error "Download failed"
            exit 1
        }
fi

echo ""
log_info "Download complete, verifying files..."

MISSING=()
for f in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "${TARGET_DIR}/${f}" ]; then
        MISSING+=("${f}")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    log_error "Download complete but missing required files: ${MISSING[*]}"
    exit 1
fi

if ! ls "${TARGET_DIR}"/*.safetensors >/dev/null 2>&1 && \
   ! ls "${TARGET_DIR}"/pytorch_model.bin >/dev/null 2>&1; then
    log_error "Download complete but no model weights file"
    exit 1
fi

TOTAL_SIZE=$(du -sh "${TARGET_DIR}" | awk '{print $1}')

echo ""
log_info "================================================"
log_info "✅ Model download complete"
log_info "================================================"
log_info "Location:    ${TARGET_DIR}"
log_info "Size:        ${TOTAL_SIZE}"
log_info "File count:  $(find "${TARGET_DIR}" -type f | wc -l)"
echo ""
log_info "vllm-worker will mount this to /model/${MODEL_LOCAL_NAME} inside Pod"
log_info "Next step: sudo bash script/lambda/launch.sh"
