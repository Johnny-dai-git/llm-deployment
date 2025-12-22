#!/bin/bash
# ============================================================
# ArgoCD Image Updater Integration Test Script
# ============================================================
# 此脚本测试 ArgoCD Image Updater 是否能正常工作
#
# 前置条件:
#   1. Kubernetes 集群已部署
#   2. ArgoCD 已安装并运行
#   3. ArgoCD Image Updater 已安装
#   4. 必要的 Secret 已创建
#
# 使用方法:
#   bash test-integration.sh
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

# Function to wait for condition
wait_for_condition() {
    local condition=$1
    local resource=$2
    local namespace=$3
    local timeout=${4:-60}
    local elapsed=0
    
    while [ $elapsed -lt $timeout ]; do
        if kubectl get "$resource" -n "$namespace" 2>/dev/null | grep -q "$condition"; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
        echo -n "."
    done
    return 1
}

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║        ArgoCD Image Updater Integration Test             ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"

TEST_ERRORS=0

# Pre-flight checks
print_section "Pre-flight Checks"

# Check kubectl
if command -v kubectl &> /dev/null; then
    print_result "pass" "kubectl is available"
    
    # Check kubectl connectivity
    if kubectl cluster-info &> /dev/null; then
        print_result "pass" "Kubernetes cluster is accessible"
    else
        print_result "fail" "Cannot connect to Kubernetes cluster"
        echo -e "${RED}Please ensure kubectl is configured correctly${NC}"
        exit 1
    fi
else
    print_result "fail" "kubectl is not available"
    exit 1
fi

# Check if argocd namespace exists
if kubectl get namespace argocd &> /dev/null; then
    print_result "pass" "argocd namespace exists"
else
    print_result "fail" "argocd namespace does not exist"
    echo -e "${YELLOW}Please install ArgoCD first${NC}"
    exit 1
fi

# Test 1: Check ArgoCD Image Updater Deployment
print_section "Test 1: ArgoCD Image Updater Deployment Status"

if kubectl get deployment argocd-image-updater -n argocd &> /dev/null; then
    print_result "pass" "Image Updater deployment exists"
    
    # Check deployment status
    READY_REPLICAS=$(kubectl get deployment argocd-image-updater -n argocd -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    DESIRED_REPLICAS=$(kubectl get deployment argocd-image-updater -n argocd -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    
    if [ "$READY_REPLICAS" = "$DESIRED_REPLICAS" ] && [ "$READY_REPLICAS" != "0" ]; then
        print_result "pass" "  Deployment is ready ($READY_REPLICAS/$DESIRED_REPLICAS replicas)"
    else
        print_result "warn" "  Deployment is not fully ready ($READY_REPLICAS/$DESIRED_REPLICAS replicas)"
        print_result "info" "  Checking pod status..."
        kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-image-updater
    fi
else
    print_result "fail" "Image Updater deployment does not exist"
    echo -e "${YELLOW}Please install ArgoCD Image Updater first${NC}"
    ((TEST_ERRORS++))
fi

# Test 2: Check Image Updater Pods
print_section "Test 2: Image Updater Pod Status"

PODS=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-image-updater -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

if [ -n "$PODS" ]; then
    print_result "pass" "Image Updater pods found"
    
    for pod in $PODS; do
        PHASE=$(kubectl get pod "$pod" -n argocd -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        READY=$(kubectl get pod "$pod" -n argocd -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
        
        if [ "$PHASE" = "Running" ] && [ "$READY" = "true" ]; then
            print_result "pass" "  Pod $pod is running and ready"
        else
            print_result "warn" "  Pod $pod status: $PHASE (ready: $READY)"
        fi
    done
else
    print_result "fail" "No Image Updater pods found"
    ((TEST_ERRORS++))
fi

# Test 3: Check Required Secrets
print_section "Test 3: Required Secrets"

# Check docker-registry-secret
if kubectl get secret docker-registry-secret -n argocd &> /dev/null; then
    print_result "pass" "docker-registry-secret exists"
    
    # Check if secret has correct type
    SECRET_TYPE=$(kubectl get secret docker-registry-secret -n argocd -o jsonpath='{.type}' 2>/dev/null || echo "")
    if [ "$SECRET_TYPE" = "kubernetes.io/dockerconfigjson" ]; then
        print_result "pass" "  Secret type is correct"
    else
        print_result "warn" "  Secret type is $SECRET_TYPE (expected: kubernetes.io/dockerconfigjson)"
    fi
else
    print_result "fail" "docker-registry-secret does not exist"
    echo -e "${YELLOW}Please create the secret: kubectl apply -f docker-registry-secret.yaml${NC}"
    ((TEST_ERRORS++))
fi

# Check git-credentials secret
if kubectl get secret git-credentials -n argocd &> /dev/null; then
    print_result "pass" "git-credentials secret exists"
    
    # Check if secret has username and password
    if kubectl get secret git-credentials -n argocd -o jsonpath='{.data.username}' &> /dev/null && \
       kubectl get secret git-credentials -n argocd -o jsonpath='{.data.password}' &> /dev/null; then
        print_result "pass" "  Secret contains username and password"
    else
        print_result "warn" "  Secret may be missing username or password fields"
    fi
else
    print_result "fail" "git-credentials secret does not exist"
    echo -e "${YELLOW}Please create the secret: kubectl apply -f git-credentials-secret.yaml${NC}"
    ((TEST_ERRORS++))
fi

# Test 4: Check Image Updater Logs
print_section "Test 4: Image Updater Logs"

if [ -n "$PODS" ]; then
    FIRST_POD=$(echo $PODS | awk '{print $1}')
    print_result "info" "Checking logs from pod: $FIRST_POD"
    
    # Get recent logs
    LOGS=$(kubectl logs "$FIRST_POD" -n argocd --tail=20 2>&1 || echo "")
    
    if [ -n "$LOGS" ]; then
        print_result "pass" "  Logs are accessible"
        
        # Check for common errors
        if echo "$LOGS" | grep -qi "error\|fatal\|panic"; then
            print_result "warn" "  Found errors in logs (check manually)"
            echo -e "${YELLOW}Recent log entries:${NC}"
            echo "$LOGS" | tail -5
        else
            print_result "pass" "  No obvious errors in recent logs"
        fi
        
        # Check for successful startup
        if echo "$LOGS" | grep -qi "started\|ready\|listening"; then
            print_result "pass" "  Image Updater appears to be running"
        fi
    else
        print_result "warn" "  Cannot retrieve logs"
    fi
else
    print_result "warn" "Cannot check logs (no pods found)"
fi

# Test 5: Check ArgoCD Applications
print_section "Test 5: ArgoCD Applications with Image Updater"

APPS=$(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

if [ -n "$APPS" ]; then
    print_result "pass" "Found ArgoCD applications"
    
    APPS_WITH_UPDATER=0
    for app in $APPS; do
        # Check if application has deployments with Image Updater annotations
        APP_PATH=$(kubectl get application "$app" -n argocd -o jsonpath='{.spec.source.path}' 2>/dev/null || echo "")
        
        if [ -n "$APP_PATH" ]; then
            # Try to find deployment files in the path
            DEPLOYMENT_FILES=$(find "$REPO_ROOT/$APP_PATH" -name "*deployment.yaml" 2>/dev/null || echo "")
            
            for dep_file in $DEPLOYMENT_FILES; do
                if [ -f "$dep_file" ] && grep -q "argocd-image-updater.argoproj.io/image-list" "$dep_file" 2>/dev/null; then
                    APPS_WITH_UPDATER=$((APPS_WITH_UPDATER + 1))
                    print_result "info" "  Application $app has deployments with Image Updater annotations"
                    break
                fi
            done
        fi
    done
    
    if [ $APPS_WITH_UPDATER -gt 0 ]; then
        print_result "pass" "Found $APPS_WITH_UPDATER application(s) with Image Updater annotations"
    else
        print_result "warn" "No applications found with Image Updater annotations"
    fi
else
    print_result "warn" "No ArgoCD applications found"
fi

# Test 6: Check Image Updater Configuration
print_section "Test 6: Image Updater Configuration"

# Check ConfigMap (if exists)
if kubectl get configmap argocd-image-updater-config -n argocd &> /dev/null; then
    print_result "pass" "Image Updater ConfigMap exists"
    
    # Check for key configurations
    CONFIG=$(kubectl get configmap argocd-image-updater-config -n argocd -o yaml 2>/dev/null || echo "")
    
    if echo "$CONFIG" | grep -q "registries:"; then
        print_result "pass" "  Registry configuration found"
    fi
    
    if echo "$CONFIG" | grep -q "git:" || echo "$CONFIG" | grep -q "writeBack:"; then
        print_result "pass" "  Git write-back configuration found"
    fi
else
    print_result "info" "ConfigMap not found (may be using Helm values directly)"
fi

# Test 7: Test Registry Connectivity (if possible)
print_section "Test 7: Registry Connectivity Test"

print_result "info" "Testing GHCR connectivity from Image Updater pod..."

if [ -n "$FIRST_POD" ]; then
    # Try to check if pod can reach GHCR
    if kubectl exec "$FIRST_POD" -n argocd -- sh -c "nc -zv ghcr.io 443 2>&1" &> /dev/null || \
       kubectl exec "$FIRST_POD" -n argocd -- sh -c "timeout 3 curl -s https://ghcr.io > /dev/null 2>&1" &> /dev/null; then
        print_result "pass" "  Pod can reach ghcr.io"
    else
        print_result "warn" "  Cannot verify connectivity to ghcr.io (may require authentication)"
    fi
else
    print_result "warn" "  Cannot test connectivity (no pods available)"
fi

# Summary
echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
if [ $TEST_ERRORS -eq 0 ]; then
    echo -e "${GREEN}║          Integration Test: PASSED                      ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${GREEN}Next Steps:${NC}"
    echo "  1. Monitor Image Updater logs:"
    echo "     ${CYAN}kubectl logs -n argocd -l app.kubernetes.io/name=argocd-image-updater -f${NC}"
    echo ""
    echo "  2. Check for image updates:"
    echo "     ${CYAN}kubectl get applications -n argocd${NC}"
    echo ""
    echo "  3. Verify Git commits (if Image Updater updates images):"
    echo "     ${CYAN}git log --oneline --grep='build: update'${NC}"
    exit 0
else
    echo -e "${RED}║          Integration Test: FAILED                      ║${NC}"
    echo -e "${RED}║          Found $TEST_ERRORS error(s)                        ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Please fix the errors above and run the test again${NC}"
    exit 1
fi

