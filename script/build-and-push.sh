#!/bin/bash
set -e

# ================================================================
# 配置区域
# ================================================================
REGISTRY="ghcr.io"
IMAGE_PREFIX="johnny-dai-git/llm-deployment"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ================================================================
# 函数定义
# ================================================================
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查 Docker 是否运行
check_docker() {
    if ! docker info > /dev/null 2>&1; then
        log_error "Docker is not running. Please start Docker first."
        exit 1
    fi
    log_info "Docker is running"
}

# 登录到 GitHub Container Registry
login_ghcr() {
    log_info "Checking GHCR authentication..."
    if ! echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$GITHUB_USERNAME" --password-stdin 2>/dev/null; then
        log_warn "GHCR login failed. Trying with docker login..."
        log_info "Please login to GHCR manually:"
        echo "  docker login ghcr.io"
        read -p "Press Enter after logging in..."
    else
        log_info "Successfully logged in to GHCR"
    fi
}

# 构建并推送单个镜像
build_and_push() {
    local service=$1
    local context=$2
    local dockerfile=$3
    local version_tag=$4
    local image_name="${REGISTRY}/${IMAGE_PREFIX}/${service}"
    local versioned_tag="${image_name}:${version_tag}"
    local latest_tag="${image_name}:latest"
    
    log_info "=========================================="
    log_info "Building ${service}..."
    log_info "Context: ${context}"
    log_info "Dockerfile: ${dockerfile}"
    log_info "Version Tag: ${version_tag}"
    log_info "Image: ${versioned_tag}"
    log_info "=========================================="
    
    # 构建镜像（同时打两个 tag：version 和 latest）
    cd "${REPO_DIR}"
    docker build \
        -f "${dockerfile}" \
        -t "${versioned_tag}" \
        -t "${latest_tag}" \
        "${context}"
    
    if [ $? -ne 0 ]; then
        log_error "Failed to build ${service}"
        return 1
    fi
    
    log_info "Successfully built ${service}"
    
    # 推送 version tag（ArgoCD Image Updater 会检测这个）
    log_info "Pushing ${versioned_tag}..."
    docker push "${versioned_tag}"
    
    if [ $? -ne 0 ]; then
        log_error "Failed to push ${service} version tag"
        return 1
    fi
    
    log_info "Successfully pushed ${versioned_tag}"
    
    # 推送 latest tag
    log_info "Pushing ${latest_tag}..."
    docker push "${latest_tag}"
    
    if [ $? -ne 0 ]; then
        log_error "Failed to push ${service} latest tag"
        return 1
    fi
    
    log_info "Successfully pushed ${latest_tag}"
    echo ""
}

# ================================================================
# 主流程
# ================================================================
main() {
    log_info "=========================================="
    log_info "Docker Build and Push Script"
    log_info "=========================================="
    echo ""
    
    # 检查 Docker
    check_docker
    
    # 检查环境变量
    if [ -z "$GITHUB_USERNAME" ]; then
        GITHUB_USERNAME="${GITHUB_USERNAME:-johnny-dai-git}"
        log_warn "GITHUB_USERNAME not set, using default: ${GITHUB_USERNAME}"
    fi
    
    if [ -z "$GITHUB_TOKEN" ]; then
        log_warn "GITHUB_TOKEN not set. You may need to login manually."
        log_info "You can set it with: export GITHUB_TOKEN=your_token"
    fi
    
    # 登录到 GHCR
    if [ -n "$GITHUB_TOKEN" ]; then
        echo "$GITHUB_TOKEN" | login_ghcr
    else
        login_ghcr
    fi
    
    # 生成符合 ArgoCD Image Updater 格式的版本 tag
    # 格式：v-YYYYMMDD-HHMMSS (例如：v-20260124-143022)
    VERSION_TAG="v-$(date +%Y%m%d-%H%M%S)"
    log_info "Generated version tag: ${VERSION_TAG}"
    log_info "This tag matches ArgoCD Image Updater pattern: regexp:^v-[0-9]{8}-[0-9]{6}$"
    echo ""
    
    log_info "Starting build and push process..."
    echo ""
    
    # 构建并推送所有镜像（传入 version tag）
    build_and_push "gateway" "app/gateway" "app/gateway/Dockerfile" "${VERSION_TAG}"
    build_and_push "router" "app/router" "app/router/Dockerfile" "${VERSION_TAG}"
    build_and_push "vllm-worker" "app/worker/vllm" "app/worker/vllm/Dockerfile" "${VERSION_TAG}"
    build_and_push "trt-worker" "app/worker/tensorRT" "app/worker/tensorRT/Dockerfile" "${VERSION_TAG}"
    build_and_push "web" "app/web" "app/web/Dockerfile" "${VERSION_TAG}"
    
    echo ""
    log_info "=========================================="
    log_info "All images built and pushed successfully!"
    log_info "=========================================="
    echo ""
    log_info "Pushed images with version tag ${VERSION_TAG}:"
    echo "  - ${REGISTRY}/${IMAGE_PREFIX}/gateway:${VERSION_TAG}"
    echo "  - ${REGISTRY}/${IMAGE_PREFIX}/router:${VERSION_TAG}"
    echo "  - ${REGISTRY}/${IMAGE_PREFIX}/vllm-worker:${VERSION_TAG}"
    echo "  - ${REGISTRY}/${IMAGE_PREFIX}/trt-worker:${VERSION_TAG}"
    echo "  - ${REGISTRY}/${IMAGE_PREFIX}/web:${VERSION_TAG}"
    echo ""
    log_info "Also pushed latest tags (for reference):"
    echo "  - ${REGISTRY}/${IMAGE_PREFIX}/gateway:latest"
    echo "  - ${REGISTRY}/${IMAGE_PREFIX}/router:latest"
    echo "  - ${REGISTRY}/${IMAGE_PREFIX}/vllm-worker:latest"
    echo "  - ${REGISTRY}/${IMAGE_PREFIX}/trt-worker:latest"
    echo "  - ${REGISTRY}/${IMAGE_PREFIX}/web:latest"
    echo ""
    log_warn "Note: ArgoCD Image Updater will automatically detect the new version tag"
    log_warn "      and update the deployments in Git (write-back method)."
    echo ""
}

# 运行主函数
main "$@"
