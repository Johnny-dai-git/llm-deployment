#!/bin/bash
# ================================================================
# 02_latency.sh — 延迟基线测试 (P50/P90/P95/P99)
# ----------------------------------------------------------------
# 在三个并发级别下各发 N 个请求,记录每个请求的端到端 latency,
# 用 awk 计算分位数。这是衡量"用户感知延迟"最直接的指标。
#
# 测试矩阵:
#   并发 1   x  N 个请求   → 串行,反映单请求最优延迟
#   并发 4   x  N 个请求   → 轻负载下的延迟稳定性
#   并发 8   x  N 个请求   → 中负载下的尾延迟(P95/P99 会涨)
# ================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
[ -z "${RESULTS_DIR:-}" ] && { init_results_dir; }

LOG="${RESULTS_DIR}/02_latency.log"
JSON="${RESULTS_DIR}/02_latency.json"

# 每个并发级别下的请求数(可调,默认 30 节省时间)
N_PER_LEVEL="${LATENCY_REQUESTS:-30}"
PROMPT="解释一下什么是机器学习,简短一些"
MAX_TOKENS=80

log_step "02 LATENCY"
log_info "每个并发级别发送 ${N_PER_LEVEL} 个请求"
log_info "prompt: \"${PROMPT}\""
log_info "max_tokens: ${MAX_TOKENS}"
echo

# 跑一组并发,把所有 latency 输出到一个文件
run_concurrency_level() {
    local conc="$1"
    local raw_file="${RESULTS_DIR}/02_latency_c${conc}.raw"
    local err_count=0

    log_info "→ 并发 ${conc} 跑 ${N_PER_LEVEL} 个请求..."
    > "${raw_file}"

    local pids=()
    local i=0
    local batch=0
    # 用 batch 模式:每次发 conc 个并发,wait,再下一批
    while [ "${i}" -lt "${N_PER_LEVEL}" ]; do
        for ((j=0; j<conc && i<N_PER_LEVEL; j++, i++)); do
            (
                result=$(do_request "${PROMPT}" "${MAX_TOKENS}" false)
                latency=$(echo "${result}" | awk '{print $1}')
                code=$(echo "${result}" | awk '{print $2}')
                if [ "${code}" = "200" ]; then
                    echo "${latency}" >> "${raw_file}"
                else
                    echo "ERR ${code}" >> "${RESULTS_DIR}/02_latency_errors.log"
                fi
            ) &
            pids+=($!)
        done
        wait "${pids[@]}" 2>/dev/null || true
        pids=()
        batch=$((batch + 1))
        # 进度提示(走 stderr,避免污染函数 stdout 返回值)
        printf "." >&2
    done
    echo >&2

    # 算分位数
    local stats
    stats=$(cat "${raw_file}" | compute_stats)
    log_info "  $(echo "${stats}" | jq -c '{count, p50_ms, p95_ms, p99_ms, mean_ms}')"
    echo "${stats}" > "${RESULTS_DIR}/02_latency_c${conc}.stats.json"
    {
        echo "=== concurrency=${conc} ==="
        echo "stats: ${stats}"
        echo "errors: ${err_count}"
        echo
    } >> "${LOG}"
    echo "${stats}"
}

# 跑三组
declare -A all_stats
all_stats[1]=$(run_concurrency_level 1)
all_stats[4]=$(run_concurrency_level 4)
all_stats[8]=$(run_concurrency_level 8)

# 汇总 JSON — 用 jq -n 构造,避免手拼字符串遇到 stats 含 newline
# 时 echo 把多行内容塞到一个 JSON 字段值里导致解析失败的问题
jq -n \
    --arg prompt "${PROMPT}" \
    --argjson reqs "${N_PER_LEVEL}" \
    --argjson max_tokens "${MAX_TOKENS}" \
    --argjson c1 "${all_stats[1]:-null}" \
    --argjson c4 "${all_stats[4]:-null}" \
    --argjson c8 "${all_stats[8]:-null}" \
    '{
        test: "02_latency",
        requests_per_level: $reqs,
        prompt: $prompt,
        max_tokens: $max_tokens,
        results: { c1: $c1, c4: $c4, c8: $c8 }
    }' > "${JSON}"

echo
log_info "===== Summary (P50/P95/P99 ms) ====="
for conc in 1 4 8; do
    p50=$(echo "${all_stats[$conc]}" | jq -r .p50_ms 2>/dev/null || echo "?")
    p95=$(echo "${all_stats[$conc]}" | jq -r .p95_ms 2>/dev/null || echo "?")
    p99=$(echo "${all_stats[$conc]}" | jq -r .p99_ms 2>/dev/null || echo "?")
    mean=$(echo "${all_stats[$conc]}" | jq -r .mean_ms 2>/dev/null || echo "?")
    printf "  c=%-2s  P50=%5sms  P95=%5sms  P99=%5sms  mean=%5sms\n" "${conc}" "${p50}" "${p95}" "${p99}" "${mean}"
done
log_info "  json: ${JSON}"
