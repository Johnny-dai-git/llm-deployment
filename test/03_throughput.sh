#!/bin/bash
# ================================================================
# 03_throughput.sh — 吞吐量测试 (tokens/sec)
# ----------------------------------------------------------------
# 在固定并发(8)下,跑不同 (prompt 长度, max_tokens) 组合,
# 看 vllm 在不同负载特征下的 throughput。
#
# 关键指标:
#   - 总耗时(秒)
#   - 总生成 token 数(从 response.usage.completion_tokens 求和)
#   - 输出 throughput = total_completion_tokens / wall_time_sec
#   - 平均 latency
#
# 比 oha 这类通用工具更准:它们看的是 HTTP 字节,
# 我们看的是真正的 LLM token 数。
# ================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
[ -z "${RESULTS_DIR:-}" ] && { init_results_dir; }

LOG="${RESULTS_DIR}/03_throughput.log"
JSON="${RESULTS_DIR}/03_throughput.json"

CONCURRENCY="${THROUGHPUT_CONCURRENCY:-8}"
N_PER_SCENARIO="${THROUGHPUT_REQUESTS:-16}"

log_step "03 THROUGHPUT"
log_info "并发 ${CONCURRENCY},每个场景跑 ${N_PER_SCENARIO} 个请求"
echo

# 一次跑一个场景,return JSON
run_scenario() {
    local name="$1"
    local prompt="$2"
    local max_tokens="$3"

    log_info "→ scenario: ${name} (max_tokens=${max_tokens})"

    # 累加器在文件里(避免子 shell 修改父变量丢失)
    local results_file="${RESULTS_DIR}/03_${name}.raw"
    > "${results_file}"

    local start_ns end_ns wall_ms
    start_ns=$(date +%s%N)

    local pids=() i=0
    while [ "${i}" -lt "${N_PER_SCENARIO}" ]; do
        for ((j=0; j<CONCURRENCY && i<N_PER_SCENARIO; j++, i++)); do
            (
                local payload
                payload=$(jq -n \
                    --arg model "${TEST_MODEL}" \
                    --arg content "${prompt}" \
                    --argjson max_tokens "${max_tokens}" \
                    '{model: $model, messages: [{role:"user", content:$content}], max_tokens: $max_tokens, stream: false}')

                local req_start req_end
                req_start=$(date +%s%N)
                resp=$(curl -fsS --max-time 90 \
                    -H "Content-Type: application/json" \
                    -X POST -d "$payload" \
                    "${TEST_ENDPOINT}" 2>/dev/null || echo '{}')
                req_end=$(date +%s%N)
                local req_lat=$(( (req_end - req_start) / 1000000 ))

                local prompt_t comp_t total_t
                prompt_t=$(echo "${resp}" | jq -r '.usage.prompt_tokens // 0' 2>/dev/null)
                comp_t=$(echo "${resp}" | jq -r '.usage.completion_tokens // 0' 2>/dev/null)
                total_t=$(echo "${resp}" | jq -r '.usage.total_tokens // 0' 2>/dev/null)

                # 一行 = "latency_ms prompt_tokens completion_tokens total_tokens"
                echo "${req_lat} ${prompt_t} ${comp_t} ${total_t}" >> "${results_file}"
            ) &
            pids+=($!)
        done
        wait "${pids[@]}" 2>/dev/null || true
        pids=()
        printf "." >&2
    done
    echo >&2

    end_ns=$(date +%s%N)
    wall_ms=$(( (end_ns - start_ns) / 1000000 ))

    # 用 awk 算汇总
    local stats
    stats=$(awk -v wall_ms="${wall_ms}" -v conc="${CONCURRENCY}" '
    {
        n++
        sum_lat  += $1
        sum_prompt += $2
        sum_comp += $3
        sum_total += $4
        if (NR == 1 || $1 < min_lat) min_lat = $1
        if (NR == 1 || $1 > max_lat) max_lat = $1
    }
    END {
        if (n == 0) { print "{}"; exit }
        wall_sec = wall_ms / 1000
        out_tok_per_sec = (wall_sec > 0) ? sum_comp / wall_sec : 0
        total_tok_per_sec = (wall_sec > 0) ? sum_total / wall_sec : 0
        rps = (wall_sec > 0) ? n / wall_sec : 0
        avg_completion = sum_comp / n
        printf "{\"requests\":%d,\"concurrency\":%d,\"wall_sec\":%.2f,\"avg_latency_ms\":%.0f,\"min_latency_ms\":%d,\"max_latency_ms\":%d,\"total_completion_tokens\":%d,\"avg_completion_tokens_per_req\":%.1f,\"output_tok_per_sec\":%.1f,\"total_tok_per_sec\":%.1f,\"rps\":%.2f}",
            n, conc, wall_sec, sum_lat/n, min_lat, max_lat, sum_comp, avg_completion, out_tok_per_sec, total_tok_per_sec, rps
    }
    ' "${results_file}")

    {
        echo "=== ${name} (max_tokens=${max_tokens}) ==="
        echo "prompt: ${prompt}"
        echo "stats: ${stats}"
        echo
    } >> "${LOG}"

    log_info "  $(echo "${stats}" | jq -c '{requests, output_tok_per_sec, avg_latency_ms, wall_sec}')"
    echo "${stats}"
}

# 三种代表性场景
SHORT_PROMPT="hi"
MED_PROMPT="解释一下什么是 transformer 架构,以及它为什么对自然语言处理重要"
LONG_PROMPT="请详细解释以下概念:神经网络反向传播算法的数学推导、梯度消失问题、Adam 优化器,以及它们之间的关系。我希望听到一个完整的故事化的回答。"

declare -A scenarios
scenarios[short_short]=$(run_scenario "short_short" "${SHORT_PROMPT}" 50)
scenarios[short_long]=$(run_scenario "short_long"  "${SHORT_PROMPT}" 300)
scenarios[long_short]=$(run_scenario "long_short"  "${LONG_PROMPT}"  50)
scenarios[long_long]=$(run_scenario "long_long"  "${LONG_PROMPT}"  300)

# 汇总 — 用 jq -n 构造 JSON,避免 echo 拼接遇到 stats 含 newline 时坏掉
jq -n \
    --argjson conc "${CONCURRENCY}" \
    --argjson reqs "${N_PER_SCENARIO}" \
    --argjson short_short "${scenarios[short_short]:-null}" \
    --argjson short_long  "${scenarios[short_long]:-null}" \
    --argjson long_short  "${scenarios[long_short]:-null}" \
    --argjson long_long   "${scenarios[long_long]:-null}" \
    '{
        test: "03_throughput",
        concurrency: $conc,
        requests_per_scenario: $reqs,
        scenarios: {
            short_short: $short_short,
            short_long:  $short_long,
            long_short:  $long_short,
            long_long:   $long_long
        }
    }' > "${JSON}"

echo
log_info "===== Summary (output tok/s) ====="
for name in short_short short_long long_short long_long; do
    tps=$(echo "${scenarios[$name]}" | jq -r .output_tok_per_sec 2>/dev/null || echo "?")
    avg=$(echo "${scenarios[$name]}" | jq -r .avg_latency_ms 2>/dev/null || echo "?")
    printf "  %-12s  output=%6s tok/s   avg_lat=%5sms\n" "${name}" "${tps}" "${avg}"
done
log_info "  json: ${JSON}"
