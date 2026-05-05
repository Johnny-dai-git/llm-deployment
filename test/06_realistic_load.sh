#!/bin/bash
# ================================================================
# 06_realistic_load.sh — Realistic load simulation
# ----------------------------------------------------------------
# Differences from 02/03:
#   - 02/03 use the same prompt repeatedly → vLLM prefix cache 100% hit,
#     measured prompt processing time is nearly 0, unrealistic
#   - 06 randomly sample prompts from data/prompts.txt → each different,
#     prefix cache hit rate ~0%, data reflects production
#
# What's tested:
#   - Real P50/P95/P99 latency (no cache acceleration)
#   - Real prompt token / completion token / total throughput
#   - Error rate
#   - Latency distribution by prompt length (split short/medium/long with awk)
#
# Usage:
#   ./06_realistic_load.sh                      # default 5 min, concurrency 8
#   REALISTIC_DURATION=600 ./06_realistic_load.sh   # run 10 min
#   REALISTIC_CONCURRENCY=16 ./06_realistic_load.sh # concurrency 16
# ================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
[ -z "${RESULTS_DIR:-}" ] && { init_results_dir; }

LOG="${RESULTS_DIR}/06_realistic.log"
JSON="${RESULTS_DIR}/06_realistic.json"
RAW="${RESULTS_DIR}/06_realistic.raw"

DURATION="${REALISTIC_DURATION:-300}"        # Default 5 minutes
CONCURRENCY="${REALISTIC_CONCURRENCY:-8}"
PROMPT_FILE="${REALISTIC_PROMPT_FILE:-${SCRIPT_DIR}/data/prompts.txt}"

# max_tokens randomized per request (simulate variety of user questions)
MAX_TOKENS_MIN=50
MAX_TOKENS_MAX=400

log_step "06 REALISTIC LOAD (random prompt + random max_tokens)"

# --- Load prompt pool (filter comments + empty lines) ---
if [ ! -f "${PROMPT_FILE}" ]; then
    log_error "Prompt file not found: ${PROMPT_FILE}"
    exit 2
fi

PROMPT_POOL="${RESULTS_DIR}/06_prompt_pool.txt"
grep -vE '^\s*(#|$)' "${PROMPT_FILE}" > "${PROMPT_POOL}"
POOL_SIZE=$(wc -l < "${PROMPT_POOL}")

if [ "${POOL_SIZE}" -lt 5 ]; then
    log_error "Prompt pool too small (${POOL_SIZE} lines), recommend >= 20"
    exit 3
fi

log_info "Prompt pool:    ${POOL_SIZE} prompts (${PROMPT_FILE})"
log_info "Concurrency:    ${CONCURRENCY}"
log_info "Duration:       ${DURATION}s"
log_info "max_tokens:     random ${MAX_TOKENS_MIN}~${MAX_TOKENS_MAX}"
echo

# Starting point
> "${RAW}"
> "${RESULTS_DIR}/06_realistic_errors.log"

start_ts=$(date +%s)
end_ts=$((start_ts + DURATION))
last_progress=${start_ts}

# Single request worker: sample one prompt from pool, random max_tokens, send request, record result
do_one_request() {
    # Randomly select one line prompt (shuf is standard GNU coreutils)
    local prompt
    prompt=$(shuf -n 1 "${PROMPT_POOL}")

    # Random max_tokens
    local mt=$((RANDOM % (MAX_TOKENS_MAX - MAX_TOKENS_MIN + 1) + MAX_TOKENS_MIN))

    # Prompt category (use length as approximation for bucketing, convenient for analysis)
    local plen=${#prompt}
    local bucket="medium"
    [ ${plen} -lt 30 ] && bucket="short"
    [ ${plen} -gt 100 ] && bucket="long"

    local payload
    payload=$(jq -nc \
        --arg model "${TEST_MODEL}" \
        --arg content "${prompt}" \
        --argjson max_tokens "${mt}" \
        '{model: $model, messages: [{role:"user", content:$content}], max_tokens: $max_tokens, stream: false}')

    local req_start req_end lat_ms
    req_start=$(date +%s%N)
    resp=$(curl -fsS --max-time 90 \
        -H "Content-Type: application/json" \
        -X POST -d "$payload" \
        "${TEST_ENDPOINT}" 2>/dev/null || echo '{}')
    req_end=$(date +%s%N)
    lat_ms=$(( (req_end - req_start) / 1000000 ))

    # Parse response
    local prompt_t comp_t total_t finish_reason
    prompt_t=$(echo "${resp}" | jq -r '.usage.prompt_tokens // "ERR"' 2>/dev/null)
    comp_t=$(echo "${resp}"   | jq -r '.usage.completion_tokens // "ERR"' 2>/dev/null)
    total_t=$(echo "${resp}"  | jq -r '.usage.total_tokens // "ERR"' 2>/dev/null)
    finish_reason=$(echo "${resp}" | jq -r '.choices[0].finish_reason // "ERR"' 2>/dev/null)

    if [ "${prompt_t}" = "ERR" ]; then
        # Failed (timeout / error response / parse failure)
        echo "FAIL ${lat_ms} ${bucket}" >> "${RAW}"
        echo "$(date '+%T') failed prompt=\"${prompt:0:60}\"" >> "${RESULTS_DIR}/06_realistic_errors.log"
    else
        # One line = "OK lat_ms bucket prompt_tokens completion_tokens total_tokens max_tokens finish_reason"
        echo "OK ${lat_ms} ${bucket} ${prompt_t} ${comp_t} ${total_t} ${mt} ${finish_reason}" >> "${RAW}"
    fi
}

# Use file lock + simple worker pool to maintain N concurrent requests
log_info "Starting load..."
pids=()
while [ "$(date +%s)" -lt "${end_ts}" ]; do
    while [ ${#pids[@]} -lt ${CONCURRENCY} ] && [ "$(date +%s)" -lt "${end_ts}" ]; do
        do_one_request &
        pids+=($!)
    done
    # Clean up completed pids
    new_pids=()
    for pid in "${pids[@]}"; do
        kill -0 "$pid" 2>/dev/null && new_pids+=("$pid")
    done
    pids=("${new_pids[@]}")
    sleep 0.2

    # Progress indicator (every minute)
    now=$(date +%s)
    if [ $((now - last_progress)) -ge 60 ]; then
        ok=$(awk '$1=="OK"' "${RAW}" | wc -l)
        err=$(awk '$1=="FAIL"' "${RAW}" | wc -l)
        elapsed=$((now - start_ts))
        remaining=$((end_ts - now))
        log_info "  t=${elapsed}s  OK=${ok}  ERR=${err}  remaining ${remaining}s"
        last_progress=${now}
    fi
done
wait "${pids[@]}" 2>/dev/null || true

end_real=$(date +%s)
wall=$((end_real - start_ts))

# ============ Analysis ============
ok_count=$(awk '$1=="OK"' "${RAW}" | wc -l)
err_count=$(awk '$1=="FAIL"' "${RAW}" | wc -l)
total_count=$((ok_count + err_count))

# Overall latency stats (all OK requests)
overall_stats=$(awk '$1=="OK" {print $2}' "${RAW}" | compute_stats)

# Latency by bucket (short/medium/long)
short_stats=$(awk '$1=="OK" && $3=="short"  {print $2}' "${RAW}" | compute_stats)
medium_stats=$(awk '$1=="OK" && $3=="medium" {print $2}' "${RAW}" | compute_stats)
long_stats=$(awk '$1=="OK" && $3=="long"   {print $2}' "${RAW}" | compute_stats)

# Token throughput (based on wall time)
totals=$(awk -v w="${wall}" '
$1=="OK" {
    sum_p += $4
    sum_c += $5
    sum_t += $6
}
END {
    if (w == 0) w = 1
    printf "{\"sum_prompt_tokens\":%d,\"sum_completion_tokens\":%d,\"sum_total_tokens\":%d,\"prompt_tok_per_sec\":%.1f,\"output_tok_per_sec\":%.1f,\"total_tok_per_sec\":%.1f}",
        sum_p, sum_c, sum_t, sum_p/w, sum_c/w, sum_t/w
}
' "${RAW}")

# finish_reason distribution (check if model truncates at max_tokens vs natural EOS)
finish_dist=$(awk '$1=="OK" {print $8}' "${RAW}" | sort | uniq -c | awk '{printf "{\"reason\":\"%s\",\"count\":%d}", $2, $1}' | paste -sd, -)

err_rate=$(awk -v ok="${ok_count}" -v err="${err_count}" \
    'BEGIN {if (ok+err==0) print 0; else printf "%.4f", err/(ok+err)*100 }')
rps=$(awk -v t="${total_count}" -v w="${wall}" \
    'BEGIN {if (w==0) print 0; else printf "%.2f", t/w}')

# ============ Write JSON ============
jq -n \
    --argjson duration   "${wall}" \
    --argjson concurrency "${CONCURRENCY}" \
    --argjson pool_size  "${POOL_SIZE}" \
    --argjson ok          "${ok_count}" \
    --argjson err         "${err_count}" \
    --argjson total       "${total_count}" \
    --argjson rps         "${rps}" \
    --argjson err_rate    "${err_rate}" \
    --argjson overall     "${overall_stats:-null}" \
    --argjson short_b     "${short_stats:-null}" \
    --argjson medium_b    "${medium_stats:-null}" \
    --argjson long_b      "${long_stats:-null}" \
    --argjson totals      "${totals:-null}" \
    --argjson finish      "[${finish_dist:-}]" \
    '{
        test: "06_realistic",
        duration_sec: $duration,
        concurrency: $concurrency,
        prompt_pool_size: $pool_size,
        ok_requests: $ok,
        err_requests: $err,
        total_requests: $total,
        error_rate_percent: $err_rate,
        rps: $rps,
        latency_ms_overall: $overall,
        latency_ms_by_prompt_size: {
            short: $short_b,
            medium: $medium_b,
            long: $long_b
        },
        token_throughput: $totals,
        finish_reason_distribution: $finish
    }' > "${JSON}"

# ============ Output ============
echo
log_info "===== Summary ====="
log_info "  duration:     ${wall}s"
log_info "  total reqs:   ${total_count}"
log_info "  OK / ERR:     ${ok_count} / ${err_count}  (rate=${err_rate}%)"
log_info "  RPS:          ${rps}"
echo
log_info "  overall latency (ms):  $(echo "${overall_stats}" | jq -c '{p50_ms, p95_ms, p99_ms, mean_ms}' 2>/dev/null)"
log_info "  short prompt:          $(echo "${short_stats}"  | jq -c '{count, p50_ms, p95_ms}'           2>/dev/null)"
log_info "  medium prompt:         $(echo "${medium_stats}" | jq -c '{count, p50_ms, p95_ms}'           2>/dev/null)"
log_info "  long prompt:           $(echo "${long_stats}"   | jq -c '{count, p50_ms, p95_ms}'           2>/dev/null)"
echo
log_info "  $(echo "${totals}" | jq -c '{output_tok_per_sec, total_tok_per_sec}' 2>/dev/null)"
log_info "  finish_reason:    [${finish_dist:-(no data)}]"
echo
log_info "  json: ${JSON}"
log_info "  raw:  ${RAW}"
