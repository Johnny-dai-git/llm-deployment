#!/bin/bash
# ================================================================
# 01_smoke.sh — 功能正确性测试
# ----------------------------------------------------------------
# 验证 LLM 服务的基本契约:
#   - /v1/models 返回模型列表
#   - 单次推理(非流式)
#   - 流式输出 SSE
#   - 多轮对话上下文
#   - 超参数(max_tokens / temperature)
#   - 错误处理(模型不存在应该 4xx 不 5xx)
# ================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

[ -z "${RESULTS_DIR:-}" ] && { init_results_dir; }
LOG="${RESULTS_DIR}/01_smoke.log"
JSON="${RESULTS_DIR}/01_smoke.json"

log_step "01 SMOKE TEST"
log_info "endpoint: ${TEST_ENDPOINT}"
log_info "model:    ${TEST_MODEL}"
log_info "log:      ${LOG}"
echo

PASS=0
FAIL=0
RESULTS=()

# 单个 case 的 helper
run_case() {
    local name="$1"
    local cmd="$2"
    local check="$3"
    local result actual
    {
        echo "=== ${name} ==="
        echo "$ ${cmd}"
        actual=$(eval "${cmd}" 2>&1)
        echo "${actual}"
        if echo "${actual}" | eval "${check}" >/dev/null 2>&1; then
            echo "RESULT: PASS"
            result="PASS"
        else
            echo "RESULT: FAIL"
            result="FAIL"
        fi
        echo
    } >> "${LOG}"

    if [ "${result}" = "PASS" ]; then
        PASS=$((PASS+1))
        log_info "✓ ${name}"
    else
        FAIL=$((FAIL+1))
        log_error "✗ ${name}"
    fi
    RESULTS+=("{\"name\":\"${name}\",\"result\":\"${result}\"}")
}

# ----- Case 1: /v1/models 返回模型列表 -----
MODELS_URL="${TEST_ENDPOINT%/v1/chat/completions}/v1/models"
run_case "models endpoint" \
    "curl -fsS --max-time 5 '${MODELS_URL}'" \
    "jq -e '.data[0].id == \"${TEST_MODEL}\"'"

# ----- Case 2: 单次推理(非流式) -----
run_case "single completion (non-streaming)" \
    "curl -fsS --max-time 30 -H 'Content-Type: application/json' -X POST -d '{\"model\":\"${TEST_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"1+1=?\"}],\"max_tokens\":50}' '${TEST_ENDPOINT}'" \
    "jq -e '.choices[0].message.content | length > 0'"

# ----- Case 3: 流式输出(SSE 应该返回 multiple data: 行) -----
run_case "streaming SSE" \
    "curl -fsS -N --max-time 30 -H 'Content-Type: application/json' -X POST -d '{\"model\":\"${TEST_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":30,\"stream\":true}' '${TEST_ENDPOINT}'" \
    "grep -c '^data: ' | awk '{exit !(\$1 >= 2)}'"

# ----- Case 4: 多轮对话(上下文记忆) -----
# 模型应该能记住前一轮 user 说过的名字。我们不强校验输出含某个字,
# 只校验返回成功且有内容(结构正确就算 PASS)。
run_case "multi-turn conversation" \
    "curl -fsS --max-time 30 -H 'Content-Type: application/json' -X POST -d '{\"model\":\"${TEST_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"我叫小明\"},{\"role\":\"assistant\",\"content\":\"你好,小明\"},{\"role\":\"user\",\"content\":\"我叫什么?\"}],\"max_tokens\":50}' '${TEST_ENDPOINT}'" \
    "jq -e '.choices[0].message.content | length > 0'"

# ----- Case 5: max_tokens 限制(显式截断) -----
# max_tokens=10 且 finish_reason 应该是 length(到 token 上限)
run_case "max_tokens enforcement" \
    "curl -fsS --max-time 30 -H 'Content-Type: application/json' -X POST -d '{\"model\":\"${TEST_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"写 1000 字的小说\"}],\"max_tokens\":10}' '${TEST_ENDPOINT}'" \
    "jq -e '.choices[0].finish_reason == \"length\"'"

# ----- Case 6: 错误处理(模型不存在) -----
# 不存在的模型应该返回 4xx,不应该 5xx 或 timeout
run_case "error handling: unknown model returns 4xx" \
    "curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -H 'Content-Type: application/json' -X POST -d '{\"model\":\"does-not-exist-99\",\"messages\":[{\"role\":\"user\",\"content\":\"x\"}]}' '${TEST_ENDPOINT}'" \
    "awk '{exit !(\$1 >= 400 && \$1 < 500)}'"

# ----- Case 7: 错误处理(空 messages) -----
run_case "error handling: empty messages returns 4xx" \
    "curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -H 'Content-Type: application/json' -X POST -d '{\"model\":\"${TEST_MODEL}\",\"messages\":[]}' '${TEST_ENDPOINT}'" \
    "awk '{exit !(\$1 >= 400 && \$1 < 500)}'"

# ----- 汇总 -----
TOTAL=$((PASS + FAIL))
{
    echo "{"
    echo "  \"test\": \"01_smoke\","
    echo "  \"total\": ${TOTAL},"
    echo "  \"pass\": ${PASS},"
    echo "  \"fail\": ${FAIL},"
    echo "  \"endpoint\": \"${TEST_ENDPOINT}\","
    echo "  \"model\": \"${TEST_MODEL}\","
    echo "  \"cases\": [$(IFS=,; echo "${RESULTS[*]}")]"
    echo "}"
} > "${JSON}"

echo
log_info "===== Summary ====="
log_info "  PASS: ${PASS} / ${TOTAL}"
[ "${FAIL}" -gt 0 ] && log_warn "  FAIL: ${FAIL}"
log_info "  json: ${JSON}"
log_info "  log:  ${LOG}"

[ "${FAIL}" -eq 0 ]
