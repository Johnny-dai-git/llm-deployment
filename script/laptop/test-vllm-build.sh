#!/bin/bash
# ================================================================
# test-vllm-build.sh
# ----------------------------------------------------------------
# Local build vllm-worker image + smoke test, verify Dockerfile
# changes work correctly. After verification, run CI / build-and-push.sh,
# avoid wasting 15 minutes of CI time due to broken Dockerfile.
#
# Usage:
#   ./test-vllm-build.sh                  # build + smoke test (default)
#   ./test-vllm-build.sh --build-only     # build only, no smoke test
#   ./test-vllm-build.sh --full           # build + full vllm server start (needs GPU)
#
# Smoke test content:
#   Only run vllm tokenizer loading flow, reproduce
#   "Qwen2Tokenizer has no attribute all_special_tokens_extended"
#   type transformers/vllm compatibility issues. No GPU needed, seconds to result.
#
# Full test (--full):
#   Actually start vllm OpenAI server, load full Qwen2 model and open port 8002.
#   Requires GPU + nvidia-container-toolkit + model files present.
# ================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Configuration
IMAGE_NAME="vllm-worker-local"
IMAGE_TAG="test-$(date +%Y%m%d-%H%M%S)"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
MODELS_DIR="${MODELS_DIR:-/home/johnny/Desktop/projects/llm-server/models}"
MODEL_NAME="qwen2.5-0.5b"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] WARN${NC} $*"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] ERROR${NC} $*" >&2; }
hr()   { echo -e "${BLUE}---------------------------------------------${NC}"; }

# Parse arguments
MODE="${1:-smoke}"
case "${MODE}" in
    --build-only|--smoke|--full|smoke|"")
        MODE="${MODE:-smoke}"
        MODE="${MODE#--}"
        ;;
    *)
        err "Unknown argument: ${MODE}"
        echo "Usage: $0 [--build-only | --smoke | --full]"
        exit 1
        ;;
esac

# ================================================================
# Step 1: docker build
# ================================================================
hr
log "Step 1/2: Local build vllm-worker image"
log "  Image:  ${FULL_IMAGE}"
log "  Source: ${REPO_DIR}/app/worker/vllm/Dockerfile"
hr

if ! docker info >/dev/null 2>&1; then
    err "Docker not running, start Docker first"
    exit 1
fi

cd "${REPO_DIR}"
if ! docker build \
        -f app/worker/vllm/Dockerfile \
        -t "${FULL_IMAGE}" \
        app/worker/vllm; then
    err "Docker build failed — Dockerfile has issues, please check"
    exit 2
fi

log "✅ Build successful"
docker images "${IMAGE_NAME}" --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}" | head -3

# ================================================================
# Mode: --build-only, exit after build
# ================================================================
if [[ "${MODE}" == "build-only" ]]; then
    hr
    log "📦 Build-only mode, skip smoke test"
    log "Next options:"
    log "  Run smoke test:  $0"
    log "  Run full test:   $0 --full"
    log "  Push to GHCR:    bash ${SCRIPT_DIR}/build-and-push.sh"
    exit 0
fi

# ================================================================
# Step 2: smoke test
# ================================================================
hr
log "Step 2/2: Smoke test"

# Check model exists
if [[ ! -d "${MODELS_DIR}/${MODEL_NAME}" ]]; then
    warn "Model directory not found: ${MODELS_DIR}/${MODEL_NAME}"
    warn "Skip smoke test. Run download-model.sh first or set MODELS_DIR env var"
    log "✅ Build passed (smoke test skipped)"
    exit 0
fi
log "✓ Model directory exists: ${MODELS_DIR}/${MODEL_NAME}"

# ----------------------------------------------------------------
# Smoke test (default): only test tokenizer loading, no GPU needed
# Can reproduce vllm 0.11.0 + transformers 5.x incompatibility bug
# (Qwen2Tokenizer has no attribute all_special_tokens_extended)
# ----------------------------------------------------------------
if [[ "${MODE}" == "smoke" ]]; then
    log "Run smoke test: load vllm tokenizer (no GPU needed, usually ~30s)"
    hr
    if docker run --rm \
            -v "${MODELS_DIR}:/model:ro" \
            "${FULL_IMAGE}" \
            python3 -c "
import sys
print('Python:', sys.version.split()[0])

import transformers
print('transformers:', transformers.__version__)

import vllm
print('vllm:', vllm.__version__)

print()
print('Loading tokenizer (this is where the bug used to manifest)...')
from vllm.transformers_utils.tokenizer import get_tokenizer
tok = get_tokenizer('/model/${MODEL_NAME}')
print('Tokenizer class:', type(tok).__name__)

# Explicitly access the attribute that previously errored to confirm it exists
attrs_to_check = ['all_special_tokens_extended', 'all_special_tokens']
for attr in attrs_to_check:
    if hasattr(tok, attr):
        print(f'  ✓ {attr}: present')
    else:
        print(f'  ✗ {attr}: MISSING')
        sys.exit(1)

print()
print('SMOKE TEST PASSED: vllm + transformers compatible')
"; then
        hr
        log "🎉 Smoke test passed! Dockerfile changes are correct"
        log ""
        log "Next steps:"
        log "  Push to GHCR (tag latest+version): bash ${SCRIPT_DIR}/build-and-push.sh"
        log "  Run full vllm server test (needs GPU):     $0 --full"
        exit 0
    else
        hr
        err "🚨 Smoke test failed!"
        err "Dockerfile changes have issues, don't push to CI"
        err "See Python error above, fix Dockerfile and re-run this script"
        exit 3
    fi
fi

# ----------------------------------------------------------------
# Full test (--full): really start vllm server, needs GPU
# ----------------------------------------------------------------
if [[ "${MODE}" == "full" ]]; then
    log "Run full test: start vllm server load model (needs GPU)"

    # Check nvidia runtime
    if ! docker info 2>/dev/null | grep -qi "nvidia"; then
        warn "Docker didn't detect nvidia runtime, may need to configure /etc/docker/daemon.json first"
        warn "Try with --gpus all (if fails, manually check nvidia-container-toolkit)"
    fi

    CONTAINER_NAME="vllm-fulltest-$$"
    LOG_FILE="/tmp/${CONTAINER_NAME}.log"

    cleanup_full() {
        log "Clean up container ${CONTAINER_NAME}"
        docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    }
    trap cleanup_full EXIT

    log "Start container ${CONTAINER_NAME} (port 18002 → container 8002)"
    docker run -d \
        --name "${CONTAINER_NAME}" \
        --gpus all \
        -p 18002:8002 \
        -v "${MODELS_DIR}:/model:ro" \
        "${FULL_IMAGE}" \
        python3 -m vllm.entrypoints.openai.api_server \
            --model "/model/${MODEL_NAME}" \
            --served-model-name "${MODEL_NAME}" \
            --host 0.0.0.0 \
            --port 8002 \
            --dtype float16 \
            --gpu-memory-utilization 0.4 \
            --max-model-len 2048 \
            --max-num-seqs 8 \
            --max-num-batched-tokens 2048 \
            --enforce-eager \
            --disable-cascade-attn

    log "Wait for vllm to start (max 180 seconds)..."
    TIMEOUT=180
    ELAPSED=0
    while [[ ${ELAPSED} -lt ${TIMEOUT} ]]; do
        docker logs "${CONTAINER_NAME}" >"${LOG_FILE}" 2>&1 || true

        # Failure signal
        if grep -qE "Traceback|AttributeError|ImportError|RuntimeError.*startup" "${LOG_FILE}"; then
            hr
            err "vllm startup failed, logs:"
            tail -50 "${LOG_FILE}"
            hr
            exit 4
        fi

        # Success signal
        if grep -qE "Application startup complete|Started server process" "${LOG_FILE}"; then
            hr
            log "✅ vllm started successfully (elapsed ${ELAPSED}s)"
            log "Test /v1/models endpoint"
            sleep 2
            if curl -fsS http://localhost:18002/v1/models | head -50; then
                hr
                log "🎉 Full test passed! Image ready to push"
                log "  bash ${SCRIPT_DIR}/build-and-push.sh"
            else
                warn "vllm started but /v1/models endpoint not responding, check logs:"
                tail -30 "${LOG_FILE}"
                exit 5
            fi
            exit 0
        fi

        sleep 3
        ELAPSED=$((ELAPSED + 3))
        echo -n "."
    done

    echo ""
    hr
    err "Wait timeout (${TIMEOUT}s), vllm didn't start"
    err "Last 80 lines of logs:"
    tail -80 "${LOG_FILE}"
    exit 6
fi
