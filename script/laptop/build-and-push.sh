#!/bin/bash
set -e

# ================================================================
# Configuration
# ================================================================
REGISTRY="ghcr.io"
IMAGE_PREFIX="johnny-dai-git/llm-deployment"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# build-and-push.sh is now in script/laptop/, repo root is one level up
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ================================================================
# Function definitions
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

# Check if Docker is running
check_docker() {
    if ! docker info > /dev/null 2>&1; then
        log_error "Docker is not running. Please start Docker first."
        exit 1
    fi
    log_info "Docker is running"
}

# Login to GitHub Container Registry
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

# Build and push single image
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
    
    # Build image (tag with both version and latest)
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
    
    # Push version tag (ArgoCD Image Updater detects this)
    log_info "Pushing ${versioned_tag}..."
    docker push "${versioned_tag}"
    
    if [ $? -ne 0 ]; then
        log_error "Failed to push ${service} version tag"
        return 1
    fi
    
    log_info "Successfully pushed ${versioned_tag}"
    
    # Push latest tag
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
# Main flow
# ================================================================
main() {
    log_info "=========================================="
    log_info "Docker Build and Push Script"
    log_info "=========================================="
    echo ""
    
    # Check Docker
    check_docker

    # Check environment variables
    if [ -z "$GITHUB_USERNAME" ]; then
        GITHUB_USERNAME="${GITHUB_USERNAME:-johnny-dai-git}"
        log_warn "GITHUB_USERNAME not set, using default: ${GITHUB_USERNAME}"
    fi
    
    if [ -z "$GITHUB_TOKEN" ]; then
        log_warn "GITHUB_TOKEN not set. You may need to login manually."
        log_info "You can set it with: export GITHUB_TOKEN=your_token"
    fi
    
    # Login to GHCR
    if [ -n "$GITHUB_TOKEN" ]; then
        echo "$GITHUB_TOKEN" | login_ghcr
    else
        login_ghcr
    fi
    
    # Generate version tag matching ArgoCD Image Updater format
    # Format: v-YYYYMMDD-HHMMSS (e.g., v-20260124-143022)
    VERSION_TAG="v-$(date +%Y%m%d-%H%M%S)"
    log_info "Generated version tag: ${VERSION_TAG}"
    log_info "This tag matches ArgoCD Image Updater pattern: regexp:^v-[0-9]{8}-[0-9]{6}$"
    echo ""
    
    log_info "Starting build and push process..."
    echo ""

    # Build and push all images (pass version tag)
    # gateway image includes merged llm-api (original gateway+router merged)
    build_and_push "gateway" "app/gateway" "app/gateway/Dockerfile" "${VERSION_TAG}"
    build_and_push "vllm-worker" "app/worker/vllm" "app/worker/vllm/Dockerfile" "${VERSION_TAG}"
    build_and_push "web" "app/web" "app/web/Dockerfile" "${VERSION_TAG}"
    
    echo ""
    log_info "=========================================="
    log_info "All images built and pushed successfully!"
    log_info "=========================================="
    echo ""
    log_info "Pushed images with version tag ${VERSION_TAG}:"
    echo "  - ${REGISTRY}/${IMAGE_PREFIX}/gateway:${VERSION_TAG}"
    echo "  - ${REGISTRY}/${IMAGE_PREFIX}/vllm-worker:${VERSION_TAG}"
    echo "  - ${REGISTRY}/${IMAGE_PREFIX}/web:${VERSION_TAG}"
    echo ""
    log_info "Also pushed latest tags (for reference):"
    echo "  - ${REGISTRY}/${IMAGE_PREFIX}/gateway:latest"
    echo "  - ${REGISTRY}/${IMAGE_PREFIX}/vllm-worker:latest"
    echo "  - ${REGISTRY}/${IMAGE_PREFIX}/web:latest"
    echo ""
    log_warn "Note: ArgoCD Image Updater will automatically detect the new version tag"
    log_warn "      and update deployments in Git (write-back method)."
    echo ""
}

# Run main function
main "$@"
