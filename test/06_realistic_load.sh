#!/bin/bash
# ================================================================
# 06_realistic_load.sh — 真实负载模拟
# ----------------------------------------------------------------
# 跟 02/03 不同的地方:
#   - 02/03 用同一个 prompt 反复打 → vLLM prefix cache 100% 命中,
#     测出来的 prompt 处理时间几乎为 0,不真实
#   - 06 从 data/prompts.txt 随机抽 prompt → 每次都不一样,
#     prefix cache 命中率接近 0%,数据贴近生产
#
# 测了什么:
#   - 真实 P50/P95/P99 延迟(无 cache 加速)
#   - 真实 prompt token / completion token / total 吞吐
#   - 错误率
#   - 不同 prompt 长度的延迟分布(用 awk 拆分 short/medium/long)
#
# 用法:
#   ./06_realistic_load.sh                      # 默认 5 分钟,并发 8
#   REALISTIC_DURATION=600 ./06_realistic_load.sh   # 跑 10 分钟
#   REALISTIC_CONCURRENCY=16 ./06_realistic_load.sh # 并发 16
# ================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
[ -z "${RESULTS_DIR:-}" ] && { init_results_dir; }

LOG="${RESULTS_DIR}/06_realistic.log"
JSON="${RESULTS_DIR}/06_realistic.json"
RAW="${RESULTS_DIR}/06_realistic.raw"

DURATION="${REALISTIC_DURATION:-300}"        # 默认 5 分钟
CONCURRENCY="${REALISTIC_CONCURRENCY:-8}"
PROMPT_FILE="${REALISTIC_PROMPT_FILE:-${SCRIPT_DIR}/data/prompts.txt}"

# max_tokens 在每个请求随机化(模拟用户问题千差万别)
MAX_TOKENS_MIN=50
MAX_TOKENS_MAX=400

log_step "06 REALISTIC LOAD (随机 prompt + 随机 max_tokens)"

# --- 加载 prompt pool(过滤注释 + 空行) ---
if [ ! -f "${PROMPT_FILE}" ]; then
    log_error "prompt 文件不存在: ${PROMPT_FILE}"
    exit 2
fi

PROMPT_POOL="${RESULTS_DIR}/06_prompt_pool.txt"
grep -vE '^\s*(#|$)' "${PROMPT_FILE}" > "${PROMPT_POOL}"
POOL_SIZE=$(wc -l < "${PROMPT_POOL}")

if [ "${POOL_SIZE}" -lt 5 ]; then
    log_error "prompt pool 太小 (${POOL_SIZE} 行),建议 >= 20"
    exit 3
fi

log_info "Prompt pool:    ${POOL_SIZE} 个(${PROMPT_FILE})"
log_info "Concurrency:    ${CONCURRENCY}"
log_info "Duration:       ${DURATION}s"
log_info "max_tokens:     随机 ${MAX_TOKENS_MIN}~${MAX_TOKENS_MAX}"
echo

# 起点
> "${RAW}"
> "${RESULTS_DIR}/06_realistic_errors.log"

start_ts=$(date +%s)
end_ts=$((start_ts + DURATION))
last_progress=${start_ts}

# 单个请求的 worker:从 pool 抽一个 prompt,随机 max_tokens,发请求,记录结果
do_one_request() {
    # 随机选一行 prompt(shuf 是 GNU coreutils 的标准命令)
    local prompt
    prompt=$(shuf -n 1 "${PROMPT_POOL}")

    # 随机 max_tokens
    local mt=$((RANDOM % (MAX_TOKENS_MAX - MAX_TOKENS_MIN + 1) + MAX_TOKENS_MIN))

    # prompt 类别(用长度近似分桶,方便后续分析)
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

    # 解析 response
    local prompt_t comp_t total_t finish_reason
    prompt_t=$(echo "${resp}" | jq -r '.usage.prompt_tokens // "ERR"' 2>/dev/null)
    comp_t=$(echo "${resp}"   | jq -r '.usage.completion_tokens // "ERR"' 2>/dev/null)
    total_t=$(echo "${resp}"  | jq -r '.usage.total_tokens // "ERR"' 2>/dev/null)
    finish_reason=$(echo "${resp}" | jq -r '.choices[0].finish_reason // "ERR"' 2>/dev/null)

    if [ "${prompt_t}" = "ERR" ]; then
        # 失败(超时 / 错误响应 / 解析失败)
        echo "FAIL ${lat_ms} ${bucket}" >> "${RAW}"
        echo "$(date '+%T') failed prompt=\"${prompt:0:60}\"" >> "${RESULTS_DIR}/06_realistic_errors.log"
    else
        # 一行 = "OK lat_ms bucket prompt_tokens completion_tokens total_tokens max_tokens finish_reason"
        echo "OK ${lat_ms} ${bucket} ${prompt_t} ${comp_t} ${total_t} ${mt} ${finish_reason}" >> "${RAW}"
    fi
}

# 用文件锁 + 简单 worker pool 维持 N 个并发
log_info "开始跑负载..."
pids=()
while [ "$(date +%s)" -lt "${end_ts}" ]; do
    while [ ${#pids[@]} -lt ${CONCURRENCY} ] && [ "$(date +%s)" -lt "${end_ts}" ]; do
        do_one_request &
        pids+=($!)
    done
    # 清理已完成的 pid
    new_pids=()
    for pid in "${pids[@]}"; do
        kill -0 "$pid" 2>/dev/null && new_pids+=("$pid")
    done
    pids=("${new_pids[@]}")
    sleep 0.2

    # 进度提示(每分钟)
    now=$(date +%s)
    if [ $((now - last_progress)) -ge 60 ]; then
        ok=$(awk '$1=="OK"' "${RAW}" | wc -l)
        err=$(awk '$1=="FAIL"' "${RAW}" | wc -l)
        elapsed=$((now - start_ts))
        remaining=$((end_ts - now))
        log_info "  t=${elapsed}s  OK=${ok}  ERR=${err}  剩 ${remaining}s"
        last_progress=${now}
    fi
done
wait "${pids[@]}" 2>/dev/null || true

end_real=$(date +%s)
wall=$((end_real - start_ts))

# ============ 分析 ============
ok_count=$(awk '$1=="OK"' "${RAW}" | wc -l)
err_count=$(awk '$1=="FAIL"' "${RAW}" | wc -l)
total_count=$((ok_count + err_count))

# 整体 latency stats(所有 OK 请求)
overall_stats=$(awk '$1=="OK" {print $2}' "${RAW}" | compute_stats)

# 按 bucket 分组的 latency(short/medium/long)
short_stats=$(awk '$1=="OK" && $3=="short"  {print $2}' "${RAW}" | compute_stats)
medium_stats=$(awk '$1=="OK" && $3=="medium" {print $2}' "${RAW}" | compute_stats)
long_stats=$(awk '$1=="OK" && $3=="long"   {print $2}' "${RAW}" | compute_stats)

# token 吞吐(基于 wall time)
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

# finish_reason 分布(看模型是不是按 max_tokens 截断 vs 自然 EOS)
finish_dist=$(awk '$1=="OK" {print $8}' "${RAW}" | sort | uniq -c | awk '{printf "{\"reason\":\"%s\",\"count\":%d}", $2, $1}' | paste -sd, -)

err_rate=$(awk -v ok="${ok_count}" -v err="${err_count}" \
    'BEGIN {if (ok+err==0) print 0; else printf "%.4f", err/(ok+err)*100 }')
rps=$(awk -v t="${total_count}" -v w="${wall}" \
    'BEGIN {if (w==0) print 0; else printf "%.2f", t/w}')

# ============ 写 JSON ============
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

# ============ 输出 ============
echo
log_info "===== Summary ====="
log_info "  duration:     ${wall}s"
log_info "  total reqs:   ${total_count}"
log_info "  OK / ERR:     ${ok_count} / ${err_count}  (rate=${err_rate}%)"
log_info "  RPS:          ${rps}"
echo
log_info "  整体延迟(ms):  $(echo "${overall_stats}" | jq -c '{p50_ms, p95_ms, p99_ms, mean_ms}' 2>/dev/null)"
log_info "  short prompt:  $(echo "${short_stats}"  | jq -c '{count, p50_ms, p95_ms}'           2>/dev/null)"
log_info "  medium prompt: $(echo "${medium_stats}" | jq -c '{count, p50_ms, p95_ms}'           2>/dev/null)"
log_info "  long prompt:   $(echo "${long_stats}"   | jq -c '{count, p50_ms, p95_ms}'           2>/dev/null)"
echo
log_info "  $(echo "${totals}" | jq -c '{output_tok_per_sec, total_tok_per_sec}' 2>/dev/null)"
log_info "  finish_reason:    [${finish_dist:-(no data)}]"
echo
log_info "  json: ${JSON}"
log_info "  raw:  ${RAW}"
