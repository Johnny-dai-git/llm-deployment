#!/bin/bash
set -e

# GitHub Access Test Script
# Tests if we can access and pull from GitHub repository

# Configuration
USERNAME="Johnny-dai-git"
TOKEN="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"
REPO="llm-deployment"
BRANCH="main"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║           GitHub Access Test Script                      ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

print_test() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}$1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

print_result() {
    if [ "$1" = "pass" ]; then
        echo -e "  ${GREEN}✓${NC} $2"
    elif [ "$1" = "fail" ]; then
        echo -e "  ${RED}✗${NC} $2"
    elif [ "$1" = "info" ]; then
        echo -e "  ${BLUE}ℹ${NC} $2"
    fi
}

# Test 1: Check git is installed
print_test "Test 1: Git Installation Check"

if command -v git &> /dev/null; then
    GIT_VERSION=$(git --version)
    print_result "pass" "Git is installed: $GIT_VERSION"
else
    print_result "fail" "Git is not installed"
    echo "  Please install git: sudo apt update && sudo apt install -y git"
    exit 1
fi

# Test 2: Test GitHub API access
print_test "Test 2: GitHub API Access Test"

echo "Testing GitHub API access with token..."
API_RESPONSE=$(curl -s -w "\n%{http_code}" -H "Authorization: token $TOKEN" \
    "https://api.github.com/user" 2>/dev/null || echo "ERROR\n000")

HTTP_CODE=$(echo "$API_RESPONSE" | tail -n1)
API_BODY=$(echo "$API_RESPONSE" | head -n-1)

if [ "$HTTP_CODE" = "200" ]; then
    print_result "pass" "GitHub API access successful (HTTP $HTTP_CODE)"
    USER_LOGIN=$(echo "$API_BODY" | grep -o '"login":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
    print_result "info" "Authenticated as: $USER_LOGIN"
else
    print_result "fail" "GitHub API access failed (HTTP $HTTP_CODE)"
    if [ "$HTTP_CODE" = "401" ]; then
        echo "  ${RED}  Token may be invalid or expired${NC}"
    elif [ "$HTTP_CODE" = "000" ]; then
        echo "  ${RED}  Network error - check internet connection${NC}"
    fi
fi

# Test 3: Test repository access
print_test "Test 3: Repository Access Test"

echo "Testing repository access..."
REPO_RESPONSE=$(curl -s -w "\n%{http_code}" -H "Authorization: token $TOKEN" \
    "https://api.github.com/repos/$USERNAME/$REPO" 2>/dev/null || echo "ERROR\n000")

REPO_HTTP_CODE=$(echo "$REPO_RESPONSE" | tail -n1)
REPO_BODY=$(echo "$REPO_RESPONSE" | head -n-1)

if [ "$REPO_HTTP_CODE" = "200" ]; then
    print_result "pass" "Repository access successful (HTTP $REPO_HTTP_CODE)"
    REPO_NAME=$(echo "$REPO_BODY" | grep -o '"full_name":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
    print_result "info" "Repository: $REPO_NAME"
    
    # Check if repository is private
    IS_PRIVATE=$(echo "$REPO_BODY" | grep -o '"private":[^,]*' | cut -d':' -f2 || echo "false")
    if [ "$IS_PRIVATE" = "true" ]; then
        print_result "info" "Repository is private - token access required"
    else
        print_result "info" "Repository is public"
    fi
else
    print_result "fail" "Repository access failed (HTTP $REPO_HTTP_CODE)"
    if [ "$REPO_HTTP_CODE" = "404" ]; then
        echo "  ${RED}  Repository not found or no access permission${NC}"
    elif [ "$REPO_HTTP_CODE" = "401" ]; then
        echo "  ${RED}  Authentication failed${NC}"
    fi
fi

# Test 4: Test HTTPS clone with token
print_test "Test 4: HTTPS Clone Test (with Token)"

TEST_DIR="/tmp/test-github-clone-$$"
GITHUB_URL="https://${TOKEN}@github.com/${USERNAME}/${REPO}.git"

echo "Attempting to clone repository to temporary directory..."
echo "URL: https://${USERNAME}:***@github.com/${USERNAME}/${REPO}.git"

# Clean up if test directory exists
rm -rf "$TEST_DIR" 2>/dev/null || true

if git clone --depth 1 -b "$BRANCH" "$GITHUB_URL" "$TEST_DIR" 2>&1; then
    print_result "pass" "HTTPS clone successful"
    
    # Check if files were cloned
    if [ -d "$TEST_DIR" ] && [ "$(ls -A $TEST_DIR 2>/dev/null)" ]; then
        FILE_COUNT=$(find "$TEST_DIR" -type f | wc -l)
        print_result "pass" "Files cloned successfully ($FILE_COUNT files)"
        
        # Check for key files
        KEY_FILES=(".github/workflows/local-build.yml" "run_all.sh" "control/run_control")
        for key_file in "${KEY_FILES[@]}"; do
            if [ -f "$TEST_DIR/$key_file" ]; then
                print_result "pass" "Key file exists: $key_file"
            else
                print_result "warn" "Key file not found: $key_file"
            fi
        done
    else
        print_result "fail" "Directory cloned but appears empty"
    fi
    
    # Clean up
    rm -rf "$TEST_DIR"
    print_result "info" "Test directory cleaned up"
else
    print_result "fail" "HTTPS clone failed"
    echo "  ${RED}  Check token permissions and repository access${NC}"
    rm -rf "$TEST_DIR" 2>/dev/null || true
fi

# Test 5: Test git pull (if in git repository)
print_test "Test 5: Git Pull Test (Current Repository)"

if [ -d ".git" ]; then
    print_result "info" "Current directory is a git repository"
    
    # Check current remote
    CURRENT_REMOTE=$(git remote get-url origin 2>/dev/null || echo "none")
    print_result "info" "Current remote: $CURRENT_REMOTE"
    
    # Test fetch
    echo "Testing git fetch..."
    if git fetch origin "$BRANCH" 2>&1 | head -5; then
        print_result "pass" "Git fetch successful"
    else
        print_result "warn" "Git fetch may have issues (check output above)"
    fi
    
    # Check if we're on the right branch
    CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
    print_result "info" "Current branch: $CURRENT_BRANCH"
    
    # Check if there are updates
    if [ "$CURRENT_BRANCH" = "$BRANCH" ]; then
        BEHIND=$(git rev-list --count HEAD..origin/$BRANCH 2>/dev/null || echo "0")
        AHEAD=$(git rev-list --count origin/$BRANCH..HEAD 2>/dev/null || echo "0")
        
        if [ "$BEHIND" -gt 0 ]; then
            print_result "info" "Local branch is $BEHIND commit(s) behind remote"
        fi
        if [ "$AHEAD" -gt 0 ]; then
            print_result "info" "Local branch is $AHEAD commit(s) ahead of remote"
        fi
        if [ "$BEHIND" -eq 0 ] && [ "$AHEAD" -eq 0 ]; then
            print_result "pass" "Local and remote are in sync"
        fi
    fi
else
    print_result "info" "Current directory is not a git repository"
fi

# Test 6: Generate test commands for run_all.sh
print_test "Test 6: Configuration for run_all.sh"

echo "For use in run_all.sh, the configuration should be:"
echo ""
echo -e "${CYAN}# GitHub repository configuration${NC}"
echo -e "${GREEN}GITHUB_USERNAME=\"$USERNAME\"${NC}"
echo -e "${GREEN}GITHUB_TOKEN=\"$TOKEN\"${NC}"
echo -e "${GREEN}GITHUB_REPO=\"$REPO\"${NC}"
echo -e "${GREEN}GITHUB_BRANCH=\"$BRANCH\"${NC}"
echo -e "${GREEN}GITHUB_URL=\"https://\${GITHUB_TOKEN}@github.com/\${GITHUB_USERNAME}/\${GITHUB_REPO}.git\"${NC}"
echo ""

# Test 7: Test credential helper (optional)
print_test "Test 7: Git Credential Helper Test"

echo "Testing git credential storage..."
GIT_CREDENTIALS_FILE="$HOME/.git-credentials"

if [ -f "$GIT_CREDENTIALS_FILE" ]; then
    print_result "info" "Git credentials file exists: $GIT_CREDENTIALS_FILE"
    if grep -q "github.com" "$GIT_CREDENTIALS_FILE"; then
        print_result "info" "GitHub credentials found in file"
    else
        print_result "warn" "No GitHub credentials in file"
    fi
else
    print_result "info" "Git credentials file does not exist"
    echo "  To store credentials, run:"
    echo "  ${CYAN}git config --global credential.helper store${NC}"
    echo "  ${CYAN}echo \"https://$USERNAME:$TOKEN@github.com\" > ~/.git-credentials${NC}"
fi

# Summary
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              GitHub Access Test Complete                 ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Summary:${NC}"
echo "  Username: $USERNAME"
echo "  Repository: $REPO"
echo "  Branch: $BRANCH"
echo "  Token: ${TOKEN:0:10}...${TOKEN: -4} (masked)"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "  1. If all tests passed, you can use these credentials in run_all.sh"
echo "  2. Test on remote nodes:"
echo "     ${CYAN}ssh user@node 'git clone https://$TOKEN@github.com/$USERNAME/$REPO.git'${NC}"
echo "  3. Or use in run_all.sh for automatic deployment"
echo ""

