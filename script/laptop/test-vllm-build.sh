#!/bin/bash
# ================================================================
# test-vllm-build.sh
# ----------------------------------------------------------------
# 本地 build vllm-worker 镜像 + smoke test,验证 Dockerfile 改动
# 是否能正常工作。验证通过之后再走 CI / build-and-push.sh,
# 避免因为 Dockerfile 改坏了导致 CI 白跑 15 分钟。
#
# 用法:
#   ./test-vllm-build.sh                  # build + smoke test (默认)
#   ./test-vllm-build.sh --build-only     # 只 build,不跑 smoke test
#   ./test-vllm-build.sh --full           # build + 完整启动 vllm server (需要 GPU)
#
# Smoke test 的内容:
#   只跑 vllm 的 tokenizer 加载流程,reproduce
#   "Qwen2Tokenizer has no attribute all_special_tokens_extended"
#   这类 transformers/vllm 兼容性问题。不需要 GPU,几秒钟出结果。
#
# Full test (--full):
#   实际启动 vllm OpenAI server,加载完整 Qwen2 模型并起 8002 端口。
#   需要 GPU + nvidia-container-toolkit + 模型文件存在。
# ================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# 配置
IMAGE_NAME="vllm-worker-local"
IMAGE_TAG="test-$(date +%Y%m%d-%H%M%S)"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
MODELS_DIR="${MODELS_DIR:-/home/johnny/Desktop/projects/llm-server/models}"
MODEL_NAME="qwen2.5-0.5b"

# 颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] WARN${NC} $*"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] ERROR${NC} $*" >&2; }
hr()   { echo -e "${BLUE}---------------------------------------------${NC}"; }

# 解析参数
MODE="${1:-smoke}"
case "${MODE}" in
    --build-only|--smoke|--full|smoke|"")
        MODE="${MODE:-smoke}"
        MODE="${MODE#--}"
        ;;
    *)
        err "未知参数: ${MODE}"
        echo "用法: $0 [--build-only | --smoke | --full]"
        exit 1
        ;;
esac

# ================================================================
# Step 1: docker build
# ================================================================
hr
log "Step 1/2: 本地 build vllm-worker 镜像"
log "  Image:  ${FULL_IMAGE}"
log "  Source: ${REPO_DIR}/app/worker/vllm/Dockerfile"
hr

if ! docker info >/dev/null 2>&1; then
    err "Docker 未运行,请先启动 Docker"
    exit 1
fi

cd "${REPO_DIR}"
if ! docker build \
        -f app/worker/vllm/Dockerfile \
        -t "${FULL_IMAGE}" \
        app/worker/vllm; then
    err "Docker build 失败 — Dockerfile 有问题,请检查"
    exit 2
fi

log "✅ Build 成功"
docker images "${IMAGE_NAME}" --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}" | head -3

# ================================================================
# Mode: --build-only,build 完就退出
# ================================================================
if [[ "${MODE}" == "build-only" ]]; then
    hr
    log "📦 仅构建模式,跳过 smoke test"
    log "下一步选项:"
    log "  跑 smoke test:  $0"
    log "  跑完整测试:     $0 --full"
    log "  推送到 GHCR:    bash ${SCRIPT_DIR}/build-and-push.sh"
    exit 0
fi

# ================================================================
# Step 2: smoke test
# ================================================================
hr
log "Step 2/2: Smoke test"

# 模型存在性检查
if [[ ! -d "${MODELS_DIR}/${MODEL_NAME}" ]]; then
    warn "模型目录不存在: ${MODELS_DIR}/${MODEL_NAME}"
    warn "跳过 smoke test。请先跑 download-model.sh 下载模型,或设置 MODELS_DIR 环境变量"
    log "✅ Build 通过(smoke test 已跳过)"
    exit 0
fi
log "✓ 模型目录存在: ${MODELS_DIR}/${MODEL_NAME}"

# ----------------------------------------------------------------
# Smoke test (默认): 只测 tokenizer 加载,无 GPU 需求
# 这能 reproduce vllm 0.11.0 + transformers 5.x 不兼容的 bug
# (Qwen2Tokenizer has no attribute all_special_tokens_extended)
# ----------------------------------------------------------------
if [[ "${MODE}" == "smoke" ]]; then
    log "运行 smoke test: 加载 vllm tokenizer (无需 GPU,通常 ~30 秒)"
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

# 显式访问之前报错的属性,确认它存在
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
        log "🎉 Smoke test 通过! Dockerfile 改动是对的"
        log ""
        log "下一步:"
        log "  推送到 GHCR(同时打 latest+version tag): bash ${SCRIPT_DIR}/build-and-push.sh"
        log "  跑完整 vllm server 测试(需要 GPU):     $0 --full"
        exit 0
    else
        hr
        err "🚨 Smoke test 失败!"
        err "Dockerfile 改动有问题,不要 push 到 CI"
        err "看上面的 Python 报错,修 Dockerfile 后重跑此 script"
        exit 3
    fi
fi

# ----------------------------------------------------------------
# Full test (--full): 真正启动 vllm server,需要 GPU
# ----------------------------------------------------------------
if [[ "${MODE}" == "full" ]]; then
    log "运行完整测试: 启动 vllm server 加载模型(需要 GPU)"

    # 检查 nvidia runtime
    if ! docker info 2>/dev/null | grep -qi "nvidia"; then
        warn "Docker 没识别到 nvidia runtime,可能需要先配置 /etc/docker/daemon.json"
        warn "尝试用 --gpus all 继续(如果失败请手动检查 nvidia-container-toolkit)"
    fi

    CONTAINER_NAME="vllm-fulltest-$$"
    LOG_FILE="/tmp/${CONTAINER_NAME}.log"

    cleanup_full() {
        log "清理容器 ${CONTAINER_NAME}"
        docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    }
    trap cleanup_full EXIT

    log "启动容器 ${CONTAINER_NAME} (端口 18002 → 容器 8002)"
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

    log "等待 vllm 启动(最多 180 秒)..."
    TIMEOUT=180
    ELAPSED=0
    while [[ ${ELAPSED} -lt ${TIMEOUT} ]]; do
        docker logs "${CONTAINER_NAME}" >"${LOG_FILE}" 2>&1 || true

        # 失败信号
        if grep -qE "Traceback|AttributeError|ImportError|RuntimeError.*startup" "${LOG_FILE}"; then
            hr
            err "vllm 启动失败,日志:"
            tail -50 "${LOG_FILE}"
            hr
            exit 4
        fi

        # 成功信号
        if grep -qE "Application startup complete|Started server process" "${LOG_FILE}"; then
            hr
            log "✅ vllm 启动成功(用时 ${ELAPSED} 秒)"
            log "测试 /v1/models 端点"
            sleep 2
            if curl -fsS http://localhost:18002/v1/models | head -50; then
                hr
                log "🎉 完整测试通过! 镜像可以推送了"
                log "  bash ${SCRIPT_DIR}/build-and-push.sh"
            else
                warn "vllm 起来了但 /v1/models 端点没响应,看下日志:"
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
    err "等待超时(${TIMEOUT}s),vllm 没起来"
    err "最后 80 行日志:"
    tail -80 "${LOG_FILE}"
    exit 6
fi
