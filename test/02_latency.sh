#!/bin/bash
# ================================================================
# 02_latency.sh — Latency baseline test (P50/P90/P95/P99)
# ----------------------------------------------------------------
# Send N requests at three concurrency levels, record end-to-end latency
# for each request, compute percentiles with awk. This is the most direct
# metric for measuring "user-perceived latency".
#
# Test matrix:
#   Concurrency 1   x  N requests   → serial, reflects optimal single-request latency
#   Concurrency 4   x  N requests   → latency stability under light load
#   Concurrency 8   x  N requests   → tail latency under medium load (P95/P99 increase)
# ================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
[ -z "${RESULTS_DIR:-}" ] && { init_results_dir; }

LOG="${RESULTS_DIR}/02_latency.log"
JSON="${RESULTS_DIR}/02_latency.json"

# Number of requests per concurrency level (tunable, default 30 to save time)
N_PER_LEVEL="${LATENCY_REQUESTS:-30}"
PROMPT="Explain machine learning briefly"
MAX_TOKENS=80

log_step "02 LATENCY"
log_info "Send ${N_PER_LEVEL} requests per concurrency level"
log_info "prompt: \"${PROMPT}\""
log_info "max_tokens: ${MAX_TOKENS}"
echo

# Run one concurrency level, output all latencies to a file
run_concurrency_level() {
    local conc="$1"
    local raw_file="${RESULTS_DIR}/02_latency_c${conc}.raw"
    local err_count=0

    log_info "→ Concurrency ${conc}: sending ${N_PER_LEVEL} requests..."
    > "${raw_file}"

    local pids=()
    local i=0
    local batch=0
    # Batch mode: send conc concurrent requests, wait, then next batch
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
        # Progress indicator (to stderr to avoid polluting function stdout)
        printf "." >&2
    done
    echo >&2

    # Compute percentiles
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

# Run three concurrency levels
declare -A all_stats
all_stats[1]=$(run_concurrency_level 1)
all_stats[4]=$(run_concurrency_level 4)
all_stats[8]=$(run_concurrency_level 8)

# Summary JSON — use jq -n to construct, avoiding manual string concatenation
# that could break if stats contains newlines
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
