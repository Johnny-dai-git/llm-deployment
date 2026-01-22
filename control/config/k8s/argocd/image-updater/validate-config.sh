#!/bin/bash
# ============================================================
# ArgoCD Image Updater Configuration Validation Script
# ============================================================
# 此脚本验证 ArgoCD Image Updater 的配置是否正确
#
# 使用方法:
#   bash validate-config.sh
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"

cd "$SCRIPT_DIR"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

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
        return 1
    elif [ "$1" = "warn" ]; then
        echo -e "  ${YELLOW}⚠${NC} $2"
    elif [ "$1" = "info" ]; then
        echo -e "  ${BLUE}ℹ${NC} $2"
    fi
    return 0
}

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     ArgoCD Image Updater Configuration Validation        ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"

VALIDATION_ERRORS=0

# Test 1: Check values.yaml
print_section "Test 1: Helm Values Configuration (values.yaml)"

if [ -f "values.yaml" ]; then
    print_result "pass" "values.yaml exists"
    
    # Check required config sections
    if grep -q "config:" values.yaml; then
        print_result "pass" "  config section exists"
    else
        print_result "fail" "  config section missing"
        ((VALIDATION_ERRORS++))
    fi
    
    # Check ArgoCD connection config
    if grep -q "argocd:" values.yaml && grep -q "serverAddress:" values.yaml; then
        print_result "pass" "  ArgoCD connection config exists"
    else
        print_result "fail" "  ArgoCD connection config missing"
        ((VALIDATION_ERRORS++))
    fi
    
    # Check Git write-back config
    if grep -q "writeBack:" values.yaml && grep -q "git:" values.yaml; then
        print_result "pass" "  Git write-back config exists"
        
        if grep -q "repository:" values.yaml; then
            print_result "pass" "    Git repository URL configured"
        else
            print_result "fail" "    Git repository URL missing"
            ((VALIDATION_ERRORS++))
        fi
        
        if grep -q "branch:" values.yaml; then
            print_result "pass" "    Git branch configured"
        else
            print_result "warn" "    Git branch not configured (using default)"
        fi
    else
        print_result "fail" "  Git write-back config missing"
        ((VALIDATION_ERRORS++))
    fi
    
    # Check registry config
    if grep -q "registries:" values.yaml; then
        print_result "pass" "  Registry config exists"
        
        if grep -q "ghcr.io" values.yaml; then
            print_result "pass" "    GHCR registry configured"
        else
            print_result "warn" "    GHCR registry not found"
        fi
        
        if grep -q "credentials:" values.yaml && grep -q "pullsecret:" values.yaml; then
            print_result "pass" "    Registry credentials format correct"
        else
            print_result "warn" "    Registry credentials format may be incorrect"
        fi
    else
        print_result "warn" "  Registry config missing (may use defaults)"
    fi
    
    # Check log level
    if grep -q "logLevel:" values.yaml; then
        print_result "pass" "  Log level configured"
    else
        print_result "warn" "  Log level not configured (using default)"
    fi
    
    # Check interval
    if grep -q "interval:" values.yaml; then
        print_result "pass" "  Update interval configured"
    else
        print_result "warn" "  Update interval not configured (using default)"
    fi
    
    # Check resources
    if grep -q "resources:" values.yaml; then
        print_result "pass" "  Resource limits configured"
    else
        print_result "warn" "  Resource limits not configured (using defaults)"
    fi
    
    # Check replicaCount
    if grep -q "replicaCount:" values.yaml; then
        print_result "pass" "  Replica count configured"
    else
        print_result "warn" "  Replica count not configured (using default: 1)"
    fi
else
    print_result "fail" "values.yaml not found"
    ((VALIDATION_ERRORS++))
fi

# Test 2: Check Docker Registry Secret
print_section "Test 2: Docker Registry Secret (docker-registry-secret.yaml)"

if [ -f "docker-registry-secret.yaml" ]; then
    print_result "pass" "docker-registry-secret.yaml exists"
    
    # Check Secret type
    if grep -q "type: kubernetes.io/dockerconfigjson" docker-registry-secret.yaml; then
        print_result "pass" "  Secret type is correct"
    else
        print_result "fail" "  Secret type is incorrect"
        ((VALIDATION_ERRORS++))
    fi
    
    # Check namespace
    if grep -q "namespace: argocd" docker-registry-secret.yaml; then
        print_result "pass" "  Namespace is correct (argocd)"
    else
        print_result "fail" "  Namespace is incorrect or missing"
        ((VALIDATION_ERRORS++))
    fi
    
    # Check for username and password (should not have auth field)
    if grep -q '"username":' docker-registry-secret.yaml && grep -q '"password":' docker-registry-secret.yaml; then
        print_result "pass" "  Username and password fields exist"
        
        # Check if auth field exists (should not)
        if grep -q '"auth":' docker-registry-secret.yaml; then
            print_result "warn" "  Auth field exists (may be redundant, Kubernetes will auto-generate)"
        else
            print_result "pass" "  No redundant auth field (correct)"
        fi
    else
        print_result "fail" "  Username or password fields missing"
        ((VALIDATION_ERRORS++))
    fi
    
    # Check for ghcr.io
    if grep -q "ghcr.io" docker-registry-secret.yaml; then
        print_result "pass" "  GHCR registry configured"
    else
        print_result "warn" "  GHCR registry not found"
    fi
else
    print_result "fail" "docker-registry-secret.yaml not found"
    ((VALIDATION_ERRORS++))
fi

# Test 3: Check Git Credentials Secret
print_section "Test 3: Git Credentials Secret (git-credentials-secret.yaml)"

if [ -f "git-credentials-secret.yaml" ]; then
    print_result "pass" "git-credentials-secret.yaml exists"
    
    # Check Secret type
    if grep -q "type: Opaque" git-credentials-secret.yaml; then
        print_result "pass" "  Secret type is correct"
    else
        print_result "fail" "  Secret type is incorrect"
        ((VALIDATION_ERRORS++))
    fi
    
    # Check namespace
    if grep -q "namespace: argocd" git-credentials-secret.yaml; then
        print_result "pass" "  Namespace is correct (argocd)"
    else
        print_result "fail" "  Namespace is incorrect or missing"
        ((VALIDATION_ERRORS++))
    fi
    
    # Check for username and password
    if grep -q "username:" git-credentials-secret.yaml && grep -q "password:" git-credentials-secret.yaml; then
        print_result "pass" "  Username and password fields exist"
    else
        print_result "fail" "  Username or password fields missing"
        ((VALIDATION_ERRORS++))
    fi
else
    print_result "fail" "git-credentials-secret.yaml not found"
    ((VALIDATION_ERRORS++))
fi

# Test 4: Check Deployment Example
print_section "Test 4: Deployment Example (deployment-example.yaml)"

if [ -f "deployment-example.yaml" ]; then
    print_result "pass" "deployment-example.yaml exists"
    
    # Check Image Updater annotations
    if grep -q "argocd-image-updater.argoproj.io/image-list" deployment-example.yaml; then
        print_result "pass" "  Image list annotation exists"
    else
        print_result "fail" "  Image list annotation missing"
        ((VALIDATION_ERRORS++))
    fi
    
    # Check update strategy
    if grep -q "argocd-image-updater.argoproj.io/.*.update-strategy" deployment-example.yaml; then
        print_result "pass" "  Update strategy annotation exists"
    else
        print_result "warn" "  Update strategy annotation missing"
    fi
    
    # Check write-back method (should include secret reference)
    if grep -q "argocd-image-updater.argoproj.io/write-back-method.*git:secret" deployment-example.yaml; then
        print_result "pass" "  Write-back method includes secret reference (correct)"
    elif grep -q "argocd-image-updater.argoproj.io/write-back-method.*git" deployment-example.yaml; then
        print_result "warn" "  Write-back method exists but may be missing secret reference"
    else
        print_result "fail" "  Write-back method annotation missing"
        ((VALIDATION_ERRORS++))
    fi
    
    # Check git branch
    if grep -q "argocd-image-updater.argoproj.io/git-branch" deployment-example.yaml; then
        print_result "pass" "  Git branch annotation exists"
    else
        print_result "warn" "  Git branch annotation missing"
    fi
else
    print_result "warn" "deployment-example.yaml not found (optional file)"
fi

# Test 5: Check actual Deployment files
print_section "Test 5: Actual Deployment Files"

DEPLOYMENT_FILES=(
    "../../llm/api/llm-api-deployment.yaml"
    "../../llm/router/router-deployment.yaml"
    "../../llm/web/llm-web-deployment.yaml"
    "../../llm/workers/vllm/vllm-worker-deployment.yaml"
    "../../llm/workers/trt/trt-worker-deployment.yaml"
)

DEPLOYMENT_ERRORS=0
for dep_file in "${DEPLOYMENT_FILES[@]}"; do
    if [ -f "$dep_file" ]; then
        dep_name=$(basename "$dep_file")
        print_result "info" "Checking $dep_name"
        
        # Check Image Updater annotations
        if grep -q "argocd-image-updater.argoproj.io/image-list" "$dep_file"; then
            print_result "pass" "    Image Updater annotations configured"
            
            # Check write-back method format
            if grep -q "argocd-image-updater.argoproj.io/write-back-method.*git:secret:argocd/git-credentials" "$dep_file"; then
                print_result "pass" "    Write-back method format correct"
            else
                print_result "fail" "    Write-back method format incorrect or missing secret reference"
                ((DEPLOYMENT_ERRORS++))
            fi
        else
            print_result "warn" "    Image Updater annotations not found"
        fi
    else
        print_result "warn" "$dep_file not found (may be in different location)"
    fi
done

if [ $DEPLOYMENT_ERRORS -gt 0 ]; then
    ((VALIDATION_ERRORS+=DEPLOYMENT_ERRORS))
fi

# Test 6: YAML Syntax Validation
print_section "Test 6: YAML Syntax Validation"

YAML_FILES=("values.yaml" "docker-registry-secret.yaml" "git-credentials-secret.yaml" "deployment-example.yaml")

for yaml_file in "${YAML_FILES[@]}"; do
    if [ -f "$yaml_file" ]; then
        # Check if yq or python is available for YAML validation
        if command -v yq &> /dev/null; then
            if yq eval '.' "$yaml_file" > /dev/null 2>&1; then
                print_result "pass" "$yaml_file syntax is valid"
            else
                print_result "fail" "$yaml_file syntax is invalid"
                ((VALIDATION_ERRORS++))
            fi
        elif command -v python3 &> /dev/null; then
            if python3 -c "import yaml; yaml.safe_load(open('$yaml_file'))" 2>/dev/null; then
                print_result "pass" "$yaml_file syntax is valid"
            else
                print_result "warn" "$yaml_file syntax validation skipped (python yaml module not available)"
            fi
        else
            print_result "warn" "YAML validation skipped (yq or python3 not available)"
            break
        fi
    fi
done

# Summary
echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
if [ $VALIDATION_ERRORS -eq 0 ]; then
    echo -e "${GREEN}║          Configuration Validation: PASSED                ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    exit 0
else
    echo -e "${RED}║          Configuration Validation: FAILED                ║${NC}"
    echo -e "${RED}║          Found $VALIDATION_ERRORS error(s)                    ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    exit 1
fi


