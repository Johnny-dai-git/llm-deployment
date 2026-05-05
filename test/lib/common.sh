#!/bin/bash
# ================================================================
# test/lib/common.sh — 共享 helper,被各个 NN_xxx.sh 引用
# ================================================================
# 设计原则:
# - 零外部依赖:只用 curl/jq/awk/bash 内建,不依赖 oha/wrk/ab/k6 等
# - 结果都落到 ${RESULTS_DIR},一份原始数据 .log + 一份指标 .json
# - 任何单个 case 失败不应中断,继续往后跑
# ================================================================

# 默认配置(可被环境变量覆盖)
# ----------------------------------------------------------------
# 如果没显式设 TEST_ENDPOINT,自动判断:
#   1. 在 Lambda 上 (能 curl 出 public IP)        → 用 public IP
#   2. localhost 能连上 ingress                    → 用 localhost
#   3. 都不行                                      → 报错
# ----------------------------------------------------------------
_detect_endpoint() {
    # 1. user 显式给了就用
    if [ -n "${TEST_ENDPOINT:-}" ]; then
        echo "${TEST_ENDPOINT}"
        return
    fi

    # 2. 试 localhost (笔记本/同机)
    if curl -fsS --max-time 2 http://localhost/api/v1/models >/dev/null 2>&1; then
        echo "http://localhost/api/v1/chat/completions"
        return
    fi

    # 3. Lambda 模式:从 ifconfig.me 拿 public IP
    local pub
    pub=$(curl -fsS --max-time 5 ifconfig.me 2>/dev/null || true)
    if [ -n "$pub" ] && curl -fsS --max-time 5 "http://${pub}/api/v1/models" >/dev/null 2>&1; then
        echo "http://${pub}/api/v1/chat/completions"
        return
    fi

    # 4. 兜底:打回 localhost,让 check_endpoint 报具体错
    echo "http://localhost/api/v1/chat/completions"
}

TEST_ENDPOINT="$(_detect_endpoint)"
TEST_MODEL="${TEST_MODEL:-qwen2.5-0.5b}"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 所有 log 都走 stderr,这样函数用 echo 在 stdout 返回数据时
# 不会被 $() 捕获污染(unix 惯例)。否则 02/03 里 run_xxx | $() 的
# 模式会把 log_info 的输出混进 stats JSON 导致 jq 解析失败。
log_info()  { echo -e "${GREEN}[$(date +%H:%M:%S) INFO]${NC} $*" >&2; }
log_warn()  { echo -e "${YELLOW}[$(date +%H:%M:%S) WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[$(date +%H:%M:%S) ERR ]${NC} $*" >&2; }
log_step()  { echo -e "${BLUE}━━━ $* ━━━${NC}" >&2; }

# 检查依赖,没装就 fail-fast
check_deps() {
    local missing=()
    for cmd in curl jq awk bc kubectl; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "缺少依赖: ${missing[*]}"
        log_error "Ubuntu 装法: sudo apt install -y ${missing[*]}"
        exit 2
    fi
}

# 测一次端点是否活着
check_endpoint() {
    if ! curl -fsS --max-time 5 "${TEST_ENDPOINT%/v1/chat/completions}/v1/models" >/dev/null 2>&1; then
        log_error "端点 ${TEST_ENDPOINT} 不可达"
        log_error "确认: kubectl get pods -n llm 全部 1/1 Running"
        exit 3
    fi
}

# 发一个 chat completions 请求,返回 latency_ms 和 HTTP code
# Usage: do_request "<prompt>" <max_tokens> [stream]
# 输出: "<latency_ms> <http_code> <bytes>"
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

# 给一组 latency_ms 数字算 percentiles,输出 JSON
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

# 集群快照:pods + HPA + node 资源
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

# 初始化 results 目录(只在 entry script 调用一次,export 给所有 sub-script)
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

# List MIG instances currently bound to pods.
# Returns lines like "MIG-13 vllm-worker-xxx" (one per attached MIG).
list_mig_pod_bindings() {
    prometheus_query 'DCGM_FI_DEV_FB_USED{pod!=""}' 2>/dev/null \
        | jq -r '.data.result[]? | "MIG-\(.metric.GPU_I_ID) \(.metric.pod)"' 2>/dev/null \
        | sort -u
}
