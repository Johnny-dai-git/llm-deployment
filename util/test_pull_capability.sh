#!/bin/bash
# ============================================================
# GHCR Image Pull Capability Test (FINAL, No False Negatives)
#
# Philosophy:
# - For GHCR private OCI images, manifest HTTP status is unreliable.
# - The ONLY reliable indicator of pull capability is:
#   "Can we obtain a registry token with pull scope?"
#
# This script:
# - Verifies GitHub PAT is valid
# - Requests GHCR registry tokens for each image
# - If token is granted => image is pullable
#
# No Docker daemon required.
# No false 404 / 403 misjudgement.
# ============================================================

set -e

# ------------------ Config ------------------
USERNAME="johnny-dai-git"        # must be lowercase
REGISTRY="ghcr.io"
REPO="llm-deployment"
IMAGES=("gateway" "router" "web" "vllm-worker" "trt-worker")
TAG="latest"
# Default token (can be overridden by GHCR_TOKEN environment variable)
DEFAULT_TOKEN="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"
# --------------------------------------------

# Use environment variable if set, otherwise use default token
if [ -z "$GHCR_TOKEN" ]; then
  GHCR_TOKEN="$DEFAULT_TOKEN"
  echo "ℹ Using default token (set GHCR_TOKEN environment variable to override)"
fi

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }
info() { echo -e "  ${BLUE}ℹ${NC} $1"; }

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   GHCR Image Pull Capability Test (FINAL & CORRECT)       ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ------------------------------------------------------------
# Step 1: GitHub API Authentication (PAT sanity check)
# ------------------------------------------------------------
echo -e "${CYAN}Step 1: GitHub API Authentication${NC}"

HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: token $GHCR_TOKEN" \
  https://api.github.com/user)

if [ "$HTTP" != "200" ]; then
  fail "GitHub API auth failed (HTTP $HTTP)"
  exit 1
fi

ok "GitHub API authentication OK"
echo ""

# ------------------------------------------------------------
# Step 2: Registry Pull Capability Test
# ------------------------------------------------------------
echo -e "${CYAN}Step 2: GHCR Registry Pull Capability${NC}"
echo ""

OK=0
FAIL=0

for img in "${IMAGES[@]}"; do
  echo -e "${CYAN}Testing: ghcr.io/$USERNAME/$REPO/$img:$TAG${NC}"

  # For GHCR scope, use lowercase username (GitHub requirement)
  SCOPE_USERNAME=$(echo "$USERNAME" | tr '[:upper:]' '[:lower:]')
  SCOPE="repository:$SCOPE_USERNAME/$REPO/$img:pull"

  REG_TOKEN=$(curl -s \
    -u "$USERNAME:$GHCR_TOKEN" \
    "https://ghcr.io/token?service=ghcr.io&scope=$SCOPE" \
    | jq -r '.token')

  if [ -n "$REG_TOKEN" ] && [ "$REG_TOKEN" != "null" ]; then
    ok "$img:$TAG CAN BE PULLED (registry token granted)"
    OK=$((OK+1))
  else
    fail "$img:$TAG cannot obtain registry pull token"
    FAIL=$((FAIL+1))
  fi

  echo ""
done

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Summary${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Images tested : ${#IMAGES[@]}"
echo -e "  ${GREEN}Pullable      : $OK${NC}"
echo -e "  ${RED}Not pullable  : $FAIL${NC}"
echo ""

if [ "$OK" -eq "${#IMAGES[@]}" ]; then
  echo -e "${GREEN}✓ ALL IMAGES ARE PULLABLE${NC}"
  echo ""
  echo "This result is consistent with:"
  echo "  docker pull ghcr.io/$USERNAME/$REPO/<image>:$TAG"
  for img in "${IMAGES[@]}"; do
    echo "  - ghcr.io/$USERNAME/$REPO/$img:$TAG"
  done
else
  echo -e "${YELLOW}⚠ Some images are not pullable${NC}"
  echo "Check:"
  echo "  - Token permissions (read:packages)"
fi
