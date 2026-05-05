#!/bin/bash
# ================================================================
# test/lib/common.sh — Shared helpers used by each NN_xxx.sh script
# ================================================================
# Design principles:
# - Zero external dependencies: only curl/jq/awk/bash built-ins, no oha/wrk/ab/k6 etc.
# - Results all go to ${RESULTS_DIR}, raw data .log + metrics .json
# - Individual case failure should not interrupt, continue running
# ================================================================

# Default configuration (can be overridden by environment variables)
# ----------------------------------------------------------------
# If TEST_ENDPOINT not explicitly set, auto-detect:
#   1. On Lambda (can curl public IP)        → use public IP
#   2. localhost can connect to ingress      → use localhost
#   3. Neither works                         → error
# ----------------------------------------------------------------
_detect_endpoint() {
    # 1. If user explicitly provided, use it
    if [ -n "${TEST_ENDPOINT:-}" ]; then
        echo "${TEST_ENDPOINT}"
        return
    fi

    # 2. Try localhost (laptop/same machine)
    if curl -fsS --max-time 2 http://localhost/api/v1/models >/dev/null 2>&1; then
        echo "http://localhost/api/v1/chat/completions"
        return
    fi

    # 3. Lambda mode: get public IP from ifconfig.me
    local pub
    pub=$(curl -fsS --max-time 5 ifconfig.me 2>/dev/null || true)
    if [ -n "$pub" ] && curl -fsS --max-time 5 "http://${pub}/api/v1/models" >/dev/null 2>&1; then
        echo "http://${pub}/api/v1/chat/completions"
        return
    fi

    # 4. Fallback: return localhost, let check_endpoint report specific error
    echo "http://localhost/api/v1/chat/completions"
}

TEST_ENDPOINT="$(_detect_endpoint)"
TEST_MODEL="${TEST_MODEL:-qwen2.5-0.5b}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# All log output goes to stderr so functions returning data via echo on stdout
# don't get polluted when captured by $() (unix convention). Otherwise the
# `run_xxx | $()` pattern in 02/03 would mix log_info output into stats JSON
# and break jq parsing.
log_info()  { echo -e "${GREEN}[$(date +%H:%M:%S) INFO]${NC} $*" >&2; }
log_warn()  { echo -e "${YELLOW}[$(date +%H:%M:%S) WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[$(date +%H:%M:%S) ERR ]${NC} $*" >&2; }
log_step()  { echo -e "${BLUE}━━━ $* ━━━${NC}" >&2; }

# Check dependencies, fail-fast if missing
check_deps() {
    local missing=()
    for cmd in curl jq awk bc kubectl; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing dependencies: ${missing[*]}"
        log_error "Ubuntu install: sudo apt install -y ${missing[*]}"
        exit 2
    fi
}

# Test if endpoint is reachable
check_endpoint() {
    if ! curl -fsS --max-time 5 "${TEST_ENDPOINT%/v1/chat/completions}/v1/models" >/dev/null 2>&1; then
        log_error "Endpoint ${TEST_ENDPOINT} unreachable"
        log_error "Verify: kubectl get pods -n llm all 1/1 Running"
        exit 3
    fi
}

# Send one chat completion request, return latency_ms and HTTP code
# Usage: do_request "<prompt>" <max_tokens> [stream]
# Output: "<latency_ms> <http_code> <bytes>"
do_request() {
    local prompt="$1"
    local max_tokens="${2:-100}"
    local stream="${3:-false}"

    local payload
    payload=$(jq -n \
        --arg model "${TEST_MODEL}" \
        --arg content "${prompt}" \
        --argjson max_tokens "${max_tokens}" \
        --argjson stream "${stream}" \
        '{model: $model, messages: [{role:"user", content:$content}], max_tokens: $max_tokens, stream: $stream}')

    local start_ns end_ns latency_ms http_code body_size
    start_ns=$(date +%s%N)
    response=$(curl -sS --max-time 60 -w "\n___HTTP_CODE___%{http_code}___SIZE___%{size_download}" \
        -H "Content-Type: application/json" \
        -X POST -d "$payload" \
        "${TEST_ENDPOINT}" 2>/dev/null || echo "___HTTP_CODE___000___SIZE___0")
    end_ns=$(date +%s%N)
    latency_ms=$(( (end_ns - start_ns) / 1000000 ))

    http_code=$(echo "$response" | sed -n 's/.*___HTTP_CODE___\([0-9]*\)___SIZE___.*/\1/p' | tail -1)
    body_size=$(echo "$response" | sed -n 's/.*___SIZE___\([0-9]*\)$/\1/p' | tail -1)

    echo "${latency_ms} ${http_code:-000} ${body_size:-0}"
}

# Compute percentiles for a group of latency_ms numbers, output JSON
# Usage: cat latencies.txt | compute_stats
compute_stats() {
    awk '
    {
        a[NR] = $1
        sum += $1
        if (NR == 1 || $1 < min) min = $1
        if (NR == 1 || $1 > max) max = $1
    }
    END {
        n = NR
        if (n == 0) { print "{}"; exit }
        # sort
        for (i=1; i<=n; i++) for (j=i+1; j<=n; j++) if (a[j]<a[i]) { t=a[i]; a[i]=a[j]; a[j]=t }
        p50_i = int(n * 0.50); if (p50_i < 1) p50_i = 1
        p90_i = int(n * 0.90); if (p90_i < 1) p90_i = 1
        p95_i = int(n * 0.95); if (p95_i < 1) p95_i = 1
        p99_i = int(n * 0.99); if (p99_i < 1) p99_i = 1
        printf "{\"count\":%d,\"min_ms\":%d,\"max_ms\":%d,\"mean_ms\":%.1f,\"p50_ms\":%d,\"p90_ms\":%d,\"p95_ms\":%d,\"p99_ms\":%d}\n", \
            n, min, max, sum/n, a[p50_i], a[p90_i], a[p95_i], a[p99_i]
    }
    '
}

# Cluster snapshot: pods + HPA + node resources
snapshot_cluster() {
    local outfile="$1"
    {
        echo "=== $(date '+%F %T') ==="
        echo "--- pods (llm) ---"
        kubectl get pods -n llm -o wide 2>/dev/null
        echo "--- pods (kube-system control plane) ---"
        kubectl get pods -n kube-system -o wide 2>/dev/null | grep -E "etcd|apiserver|controller-manager|scheduler" || true
        echo "--- HPA (llm) ---"
        kubectl get hpa -n llm 2>/dev/null
        echo "--- node resources ---"
        kubectl describe node 2>/dev/null | grep -A 6 "Allocated resources" | head -15
        echo
    } >> "${outfile}"
}

# Initialize results directory (call once in entry script, export to all sub-scripts)
init_results_dir() {
    if [ -z "${RESULTS_DIR:-}" ]; then
        RESULTS_DIR="${SCRIPT_DIR}/results/$(date +%Y%m%d-%H%M%S)"
        mkdir -p "${RESULTS_DIR}"
        export RESULTS_DIR
    fi
    log_info "Results: ${RESULTS_DIR}"
}

# ================================================================
# MIG-aware helpers
# ----------------------------------------------------------------
# Query Prometheus for a single value. Used by 07_mig_isolation.sh
# to count how many MIG instances are actually doing GPU work.
# Prometheus is exposed via ingress at /prometheus.
# ================================================================
prometheus_query() {
    local query="$1"
    local prom_url
    # Strip /api/v1/chat/completions, append /prometheus/api/v1/query
    prom_url="${TEST_ENDPOINT%/api/v1/chat/completions}/prometheus/api/v1/query"
    curl -fsS -G --max-time 10 \
        --data-urlencode "query=${query}" \
        "${prom_url}" 2>/dev/null
}

# Count how many MIG instances had non-zero compute activity over the last $window.
# Returns single integer or "0" on error.
count_active_mig_instances() {
    local window="${1:-1m}"
    prometheus_query "count(max_over_time(DCGM_FI_PROF_GR_ENGINE_ACTIVE[${window}]) > 0.05)" \
        | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null \
        || echo "0"
}

# List MIG instances currently bound to vLLM pods.
# Returns lines like "MIG-13 vllm-worker-xxx" (one per attached MIG).
# Note: Prometheus relabels DCGM's `pod` to `exported_pod` because the
# scraping pod is the dcgm-exporter itself; the workload pod label moves
# to exported_pod. We filter on that to only see workload pods, not the
# exporter pod's own self-record.
list_mig_pod_bindings() {
    prometheus_query 'DCGM_FI_DEV_FB_USED{exported_pod!=""}' 2>/dev/null \
        | jq -r '.data.result[]? | "MIG-\(.metric.GPU_I_ID) \(.metric.exported_pod)"' 2>/dev/null \
        | sort -u
}
