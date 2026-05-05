#!/bin/bash
# ================================================================
# 01_smoke.sh — Functional correctness test
# ----------------------------------------------------------------
# Verify LLM service basic contract:
#   - /v1/models returns model list
#   - Single inference (non-streaming)
#   - Streaming output (SSE)
#   - Multi-turn conversation context
#   - Hyperparameters (max_tokens / temperature)
#   - Error handling (non-existent model should 4xx not 5xx)
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

# Helper for individual test case
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

# ----- Case 1: /v1/models returns model list -----
MODELS_URL="${TEST_ENDPOINT%/v1/chat/completions}/v1/models"
run_case "models endpoint" \
    "curl -fsS --max-time 5 '${MODELS_URL}'" \
    "jq -e '.data[0].id == \"${TEST_MODEL}\"'"

# ----- Case 2: Single inference (non-streaming) -----
run_case "single completion (non-streaming)" \
    "curl -fsS --max-time 30 -H 'Content-Type: application/json' -X POST -d '{\"model\":\"${TEST_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"1+1=?\"}],\"max_tokens\":50}' '${TEST_ENDPOINT}'" \
    "jq -e '.choices[0].message.content | length > 0'"

# ----- Case 3: Streaming output (SSE should return multiple data: lines) -----
run_case "streaming SSE" \
    "curl -fsS -N --max-time 30 -H 'Content-Type: application/json' -X POST -d '{\"model\":\"${TEST_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":30,\"stream\":true}' '${TEST_ENDPOINT}'" \
    "grep -c '^data: ' | awk '{exit !(\$1 >= 2)}'"

# ----- Case 4: Multi-turn conversation (context memory) -----
# Model should remember the name from the previous user message.
# We don't strictly verify specific output content,
# just verify successful return with content (correct structure = PASS).
run_case "multi-turn conversation" \
    "curl -fsS --max-time 30 -H 'Content-Type: application/json' -X POST -d '{\"model\":\"${TEST_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"My name is Alice\"},{\"role\":\"assistant\",\"content\":\"Hello Alice\"},{\"role\":\"user\",\"content\":\"What is my name?\"}],\"max_tokens\":50}' '${TEST_ENDPOINT}'" \
    "jq -e '.choices[0].message.content | length > 0'"

# ----- Case 5: max_tokens enforcement (explicit truncation) -----
# max_tokens=10 and finish_reason should be 'length' (hit token limit)
run_case "max_tokens enforcement" \
    "curl -fsS --max-time 30 -H 'Content-Type: application/json' -X POST -d '{\"model\":\"${TEST_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Write a 1000-word story\"}],\"max_tokens\":10}' '${TEST_ENDPOINT}'" \
    "jq -e '.choices[0].finish_reason == \"length\"'"

# ----- Case 6: Error handling (non-existent model) -----
# Non-existent model should return 4xx, not 5xx or timeout
run_case "error handling: unknown model returns 4xx" \
    "curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -H 'Content-Type: application/json' -X POST -d '{\"model\":\"does-not-exist-99\",\"messages\":[{\"role\":\"user\",\"content\":\"x\"}]}' '${TEST_ENDPOINT}'" \
    "awk '{exit !(\$1 >= 400 && \$1 < 500)}'"

# ----- Case 7: Error handling (empty messages) -----
run_case "error handling: empty messages returns 4xx" \
    "curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -H 'Content-Type: application/json' -X POST -d '{\"model\":\"${TEST_MODEL}\",\"messages\":[]}' '${TEST_ENDPOINT}'" \
    "awk '{exit !(\$1 >= 400 && \$1 < 500)}'"

# ----- Summary -----
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
