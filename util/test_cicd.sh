#!/bin/bash
set -e

# CI/CD Testing Script
# This script helps test the CI/CD pipeline step by step

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║           CI/CD Pipeline Testing Script                   ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Function to print section header
print_section() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}$1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# Function to print test result
print_result() {
    if [ "$1" = "pass" ]; then
        echo -e "  ${GREEN}✓${NC} $2"
    elif [ "$1" = "fail" ]; then
        echo -e "  ${RED}✗${NC} $2"
    elif [ "$1" = "warn" ]; then
        echo -e "  ${YELLOW}⚠${NC} $2"
    elif [ "$1" = "info" ]; then
        echo -e "  ${BLUE}ℹ${NC} $2"
    fi
}

# Test 1: Check GitHub Actions workflow file
print_section "Test 1: GitHub Actions Workflow Configuration"

if [ -f ".github/workflows/local-build.yml" ]; then
    print_result "pass" "Workflow file exists: .github/workflows/local-build.yml"
    
    # Check if workflow is configured for self-hosted runner
    if grep -q "runs-on: self-hosted" .github/workflows/local-build.yml; then
        print_result "pass" "Configured for self-hosted runner"
    else
        print_result "fail" "Not configured for self-hosted runner"
    fi
    
    # Check registry configuration
    if grep -q "REGISTRY: ghcr.io" .github/workflows/local-build.yml; then
        print_result "pass" "Registry configured as ghcr.io"
    else
        print_result "fail" "Registry not configured correctly"
    fi
    
    # Check image prefix
    if grep -q "IMAGE_PREFIX.*llm-deployment" .github/workflows/local-build.yml; then
        print_result "pass" "Image prefix configured correctly"
    else
        print_result "warn" "Image prefix may not be configured"
    fi
else
    print_result "fail" "Workflow file not found: .github/workflows/local-build.yml"
fi

# Test 2: Check Docker images configuration
print_section "Test 2: Docker Images Configuration in CI/CD"

IMAGES=("gateway" "router" "vllm-worker" "trt-worker" "web")
ALL_IMAGES_OK=true

for img in "${IMAGES[@]}"; do
    if grep -q "ghcr.io/.*llm-deployment/$img" .github/workflows/local-build.yml; then
        print_result "pass" "$img image configured in workflow"
    else
        print_result "fail" "$img image not found in workflow"
        ALL_IMAGES_OK=false
    fi
done

if [ "$ALL_IMAGES_OK" = true ]; then
    echo ""
    print_result "info" "All 5 images are configured in CI/CD workflow"
fi

# Test 3: Check K8s deployment files
print_section "Test 3: Kubernetes Deployment Files Configuration"

DEPLOYMENTS=(
    "control/config/k8s/llm/api/llm-api-deployment.yaml:gateway"
    "control/config/k8s/llm/router/router-deployment.yaml:router"
    "control/config/k8s/llm/web/llm-web-deployment.yaml:web"
    "control/config/k8s/llm/workers/vllm/vllm-worker-deployment.yaml:vllm-worker"
    "control/config/k8s/llm/workers/trt/trt-worker-deployment.yaml:trt-worker"
)

ALL_DEPLOYMENTS_OK=true

for dep_info in "${DEPLOYMENTS[@]}"; do
    dep_file=$(echo "$dep_info" | cut -d: -f1)
    dep_name=$(echo "$dep_info" | cut -d: -f2)
    
    if [ -f "$dep_file" ]; then
        echo ""
        print_result "pass" "$(basename $dep_file) exists"
        
        # Check image path
        if grep -q "ghcr.io/johnny-dai-git/llm-deployment" "$dep_file"; then
            print_result "pass" "  Image path configured correctly"
        else
            print_result "fail" "  Image path not configured correctly"
            ALL_DEPLOYMENTS_OK=false
        fi
        
        # Check imagePullSecrets (should not be present for public images)
        if grep -q "imagePullSecrets" "$dep_file"; then
            print_result "warn" "  imagePullSecrets found (not needed for public images)"
        else
            print_result "pass" "  No imagePullSecrets (public images, correct)"
        fi
        
        # Check ArgoCD Image Updater annotations
        if grep -q "argocd-image-updater.argoproj.io/image-list" "$dep_file"; then
            print_result "pass" "  ArgoCD Image Updater annotations configured"
        else
            print_result "warn" "  ArgoCD Image Updater annotations not found"
        fi
        
        # Check write-back method
        if grep -q "argocd-image-updater.argoproj.io/write-back-method.*git" "$dep_file"; then
            print_result "pass" "  Image Updater write-back method configured"
        else
            print_result "warn" "  Image Updater write-back method not configured"
        fi
    else
        print_result "fail" "$dep_file not found"
        ALL_DEPLOYMENTS_OK=false
    fi
done

# Test 4: Check Secrets configuration
print_section "Test 4: Secrets Configuration"

# Check ghcr-secret for K8s (not needed for public images)
if [ -f "control/config/k8s/llm/secrets/ghcr-secret.yaml" ]; then
    print_result "warn" "ghcr-secret.yaml exists (not needed for public images, can be removed)"
else
    print_result "pass" "ghcr-secret.yaml not found (correct for public images)"
fi

# Check docker-registry-secret for ArgoCD Image Updater
if [ -f "control/config/k8s/argocd-image-updater/image-updater/docker-registry-secret.yaml" ]; then
    print_result "pass" "docker-registry-secret.yaml exists (for ArgoCD Image Updater)"
    if grep -q "Johnny-dai-git" "control/config/k8s/argocd-image-updater/image-updater/docker-registry-secret.yaml"; then
        print_result "pass" "  Username configured"
    else
        print_result "warn" "  Username may be placeholder"
    fi
    if grep -q "ghcr.io" "control/config/k8s/argocd-image-updater/image-updater/docker-registry-secret.yaml"; then
        print_result "pass" "  Registry URL configured (ghcr.io)"
    else
        print_result "warn" "  Registry URL may not be configured"
    fi
else
    print_result "fail" "docker-registry-secret.yaml not found"
fi

# Check git-credentials-secret for ArgoCD Image Updater
if [ -f "control/config/k8s/argocd-image-updater/image-updater/git-credentials-secret.yaml" ]; then
    print_result "pass" "git-credentials-secret.yaml exists (for ArgoCD Image Updater)"
    if grep -q "Johnny-dai-git" "control/config/k8s/argocd-image-updater/image-updater/git-credentials-secret.yaml"; then
        print_result "pass" "  Username configured"
    else
        print_result "warn" "  Username may be placeholder"
    fi
    if grep -q "argocd-image-updater-config" "control/config/k8s/argocd-image-updater/image-updater/git-credentials-secret.yaml"; then
        print_result "pass" "  ConfigMap configuration included"
    else
        print_result "warn" "  ConfigMap configuration may be missing"
    fi
else
    print_result "fail" "git-credentials-secret.yaml not found"
fi

# Test 5: Check Dockerfile existence
print_section "Test 5: Dockerfile Configuration"

DOCKERFILES=(
    "gateway/Dockerfile:gateway"
    "system/Dockerfile:router"
    "web/Dockerfile:web"
    "worker/vllm/Dockerfile:vllm-worker"
    "worker/tensorRT/Dockerfile:trt-worker"
)

for df_info in "${DOCKERFILES[@]}"; do
    df_file=$(echo "$df_info" | cut -d: -f1)
    df_name=$(echo "$df_info" | cut -d: -f2)
    
    if [ -f "$df_file" ]; then
        print_result "pass" "$df_name: $df_file exists"
    else
        print_result "fail" "$df_name: $df_file not found"
    fi
done

# Test 6: Summary and next steps
print_section "Test Summary and Next Steps"

echo -e "${YELLOW}Manual Testing Steps:${NC}"
echo ""
echo -e "${BLUE}Step 1:${NC} Test GitHub Actions Workflow"
echo "  1. Commit and push your changes:"
echo "     ${CYAN}./util/commit_all.sh \"test: trigger CI/CD pipeline\" --push${NC}"
echo ""
echo "  2. Or manually trigger workflow:"
echo "     - Go to GitHub repository"
echo "     - Click 'Actions' tab"
echo "     - Select 'Build and Push Docker Images'"
echo "     - Click 'Run workflow'"
echo ""
echo "  3. Monitor workflow execution:"
echo "     - Check Actions tab for execution status"
echo "     - Verify all images are built successfully"
echo "     - Check for any errors"
echo ""

echo -e "${BLUE}Step 2:${NC} Verify Images in Registry"
echo "  1. Visit GitHub Packages:"
echo "     ${CYAN}https://github.com/Johnny-dai-git?tab=packages${NC}"
echo ""
echo "  2. Verify these images exist:"
for img in "${IMAGES[@]}"; do
    echo "     • ghcr.io/johnny-dai-git/llm-deployment/$img"
done
echo ""
echo "  3. Test image pull (if Docker is installed):"
echo "     ${CYAN}echo 'ghp_YOUR_TOKEN' | docker login ghcr.io -u johnny-dai-git --password-stdin${NC}"
echo "     ${CYAN}docker pull ghcr.io/johnny-dai-git/llm-deployment/gateway:latest${NC}"
echo ""

echo -e "${BLUE}Step 3:${NC} Test Kubernetes Deployment (if cluster is ready)"
echo "  1. Apply secrets (for ArgoCD Image Updater only, not needed for public images):"
echo "     ${CYAN}cd control${NC}"
echo "     ${CYAN}kubectl apply -f config/k8s/argocd-image-updater/image-updater/docker-registry-secret.yaml${NC}"
echo "     ${CYAN}kubectl apply -f config/k8s/argocd-image-updater/image-updater/git-credentials-secret.yaml${NC}"
echo ""
echo "  2. Run deployment script:"
echo "     ${CYAN}bash run_control${NC}"
echo ""
echo "  3. Check ArgoCD status:"
echo "     ${CYAN}kubectl get pods -n argocd${NC}"
echo "     ${CYAN}kubectl get applications -n argocd${NC}"
echo ""

echo -e "${BLUE}Step 4:${NC} Test ArgoCD Image Updater (if K8s is deployed)"
echo "  1. Trigger new build:"
echo "     - Make a small change (e.g., update web/index.html)"
echo "     - Commit and push: ${CYAN}./util/commit_all.sh --push${NC}"
echo ""
echo "  2. Monitor Image Updater:"
echo "     ${CYAN}kubectl logs -n argocd -l app.kubernetes.io/name=argocd-image-updater --tail=50${NC}"
echo ""
echo "  3. Check Git repository for auto-updates:"
echo "     ${CYAN}git log --oneline -5${NC}"
echo ""
echo "  4. Check ArgoCD sync status:"
echo "     - Access ArgoCD UI"
echo "     - Verify applications auto-sync"
echo ""

echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              Configuration Check Complete                 ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Quick Start:${NC}"
echo "  1. Run: ${CYAN}./util/test_cicd.sh${NC} (this script)"
echo "  2. Commit changes: ${CYAN}./util/commit_all.sh${NC}"
echo "  3. Monitor: GitHub Actions tab"
echo "  4. Verify: GitHub Packages page"
echo ""

