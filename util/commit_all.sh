#!/bin/bash
set -e

# Git commit script for all changes
# Usage: ./util/commit_all.sh [commit_message] [--push]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Git Commit All Changes Script ===${NC}"
echo ""

# Check if git repository
if [ ! -d ".git" ]; then
    echo -e "${RED}Error: Not a git repository${NC}"
    exit 1
fi

# Check git status
echo -e "${YELLOW}Checking git status...${NC}"
git status --short

# Check if there are changes
if [ -z "$(git status --porcelain)" ]; then
    echo -e "${YELLOW}No changes to commit.${NC}"
    exit 0
fi

echo ""
echo -e "${YELLOW}Changes detected:${NC}"
git status --short
echo ""

# Get commit message
if [ -n "$1" ] && [ "$1" != "--push" ]; then
    COMMIT_MSG="$1"
else
    # Generate commit message based on changes
    echo -e "${BLUE}Generating commit message from changes...${NC}"
    
    # Detect what changed
    CHANGED_FILES=$(git status --porcelain | awk '{print $2}')
    
    MSG_PARTS=()
    
    # Check for CI/CD changes
    if echo "$CHANGED_FILES" | grep -qE "\.(yml|yaml)$|\.github/"; then
        MSG_PARTS+=("ci/cd")
    fi
    
    # Check for K8s changes
    if echo "$CHANGED_FILES" | grep -qE "k8s/|deployment|service|configmap|secret"; then
        MSG_PARTS+=("k8s")
    fi
    
    # Check for script changes
    if echo "$CHANGED_FILES" | grep -qE "\.sh$|run_|install/"; then
        MSG_PARTS+=("scripts")
    fi
    
    # Check for Docker changes
    if echo "$CHANGED_FILES" | grep -qE "Dockerfile|docker"; then
        MSG_PARTS+=("docker")
    fi
    
    # Check for web changes
    if echo "$CHANGED_FILES" | grep -qE "web/|\.html$|\.js$|\.css$"; then
        MSG_PARTS+=("web")
    fi
    
    # Check for ArgoCD changes
    if echo "$CHANGED_FILES" | grep -qE "argocd|image-updater"; then
        MSG_PARTS+=("argocd")
    fi
    
    # Check for util changes
    if echo "$CHANGED_FILES" | grep -qE "util/"; then
        MSG_PARTS+=("util")
    fi
    
    # Default message
    if [ ${#MSG_PARTS[@]} -eq 0 ]; then
        COMMIT_MSG="chore: update files"
    else
        COMMIT_MSG="feat: update $(IFS=,; echo "${MSG_PARTS[*]}")"
    fi
    
    echo -e "${GREEN}Generated commit message: ${COMMIT_MSG}${NC}"
fi

# Add all changes
echo ""
echo -e "${YELLOW}Adding all changes...${NC}"
git add -A

# Show what will be committed
echo ""
echo -e "${YELLOW}Files to be committed:${NC}"
git status --short

# Confirm commit
echo ""
read -p "Commit with message: '${COMMIT_MSG}'? (y/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${RED}Commit cancelled.${NC}"
    exit 1
fi

# Commit
echo ""
echo -e "${YELLOW}Committing changes...${NC}"
git commit -m "$COMMIT_MSG"

echo ""
echo -e "${GREEN}✓ Commit successful!${NC}"
echo ""

# Check if should push
SHOULD_PUSH=false
if [ "$1" == "--push" ] || [ "$2" == "--push" ]; then
    SHOULD_PUSH=true
else
    read -p "Push to remote? (y/n) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        SHOULD_PUSH=true
    fi
fi

if [ "$SHOULD_PUSH" = true ]; then
    echo ""
    echo -e "${YELLOW}Pushing to remote...${NC}"
    CURRENT_BRANCH=$(git branch --show-current)
    git push origin "$CURRENT_BRANCH"
    echo ""
    echo -e "${GREEN}✓ Push successful!${NC}"
fi

echo ""
echo -e "${GREEN}=== Done ===${NC}"
