#!/bin/bash
# ================================================================
# run_lambda.sh — Lambda A100 / GCP_BRANCH 全套压力测试入口
# ----------------------------------------------------------------
# 跟 run_all.sh 的差别:
#   - 自动检测 public IP (从 ifconfig.me),设 TEST_ENDPOINT
#   - 默认参数针对 A100 + 7 MIG 调高:
#     · HPA 测试并发 30 (vs laptop 10) —— 真把 HPA 推到 7 副本
#     · realistic 负载并发 14 (vs 8)    —— 7 MIG × 2
#   - 多跑 07_mig_isolation —— Lambda 才有意义的测试
#   - SUMMARY.md 加一段 vs laptop baseline 对比
#
# 用法:
#   ./run_lambda.sh                 # 全套 (~20 分钟)
#   ./run_lambda.sh smoke latency   # 只跑指定子集
#
# 环境变量(可覆盖默认值):
#   TEST_ENDPOINT          - 默认从 ifconfig.me 取
#   HPA_LOAD_CONCURRENCY   - 默认 30
#   HPA_LOAD_DURATION      - 默认 240 秒(给 HPA 充分时间扩到 7)
#   MIG_LOAD_CONCURRENCY   - 默认 20 (07 测试用)
# ================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============ 自动检测 public IP ============
if [ -z "${TEST_ENDPOINT:-}" ]; then
    PUB_IP=$(curl -fsS --max-time 5 ifconfig.me 2>/dev/null || true)
    if [ -n "$PUB_IP" ]; then
        export TEST_ENDPOINT="http://${PUB_IP}/api/v1/chat/completions"
        echo ">>> Auto-detected public endpoint: ${TEST_ENDPOINT}"
    else
        echo "⚠️  ifconfig.me 不可达,fallback to localhost"
        export TEST_ENDPOINT="http://localhost/api/v1/chat/completions"
    fi
fi

# ============ Lambda 调高的默认参数 ============
# laptop default → Lambda recommended:
#   HPA_LOAD_CONCURRENCY: 10  → 30
#   HPA_LOAD_DURATION:    180 → 240   (给 HPA 充分扩到 7)
#   MIG_LOAD_CONCURRENCY: 20  (新)
#   MIG_LOAD_DURATION:    90  (新)
export HPA_LOAD_CONCURRENCY="${HPA_LOAD_CONCURRENCY:-30}"
export HPA_LOAD_DURATION="${HPA_LOAD_DURATION:-240}"
export MIG_LOAD_CONCURRENCY="${MIG_LOAD_CONCURRENCY:-20}"
export MIG_LOAD_DURATION="${MIG_LOAD_DURATION:-90}"
export STABILITY_DURATION="${STABILITY_DURATION:-300}"

source "${SCRIPT_DIR}/lib/common.sh"

check_deps
check_endpoint
init_results_dir

# ============ 选择性跑子集 ============
SELECTED=("$@")
should_run() {
    local name="$1"
    [ ${#SELECTED[@]} -eq 0 ] && return 0
    for s in "${SELECTED[@]}"; do
        [ "$s" = "$name" ] && return 0
    done
    return 1
}

# 7 个测试,07 是 Lambda-only
TESTS=(
    "smoke|01_smoke.sh|功能性 smoke (7 case)"
    "latency|02_latency.sh|延迟 (concurrency 1/4/8)"
    "throughput|03_throughput.sh|吞吐 (4 个 prompt-output 组合)"
    "hpa|04_hpa.sh|HPA 扩容 (1↔7 expected on Lambda)"
    "stability|05_stability.sh|稳定性 (${STABILITY_DURATION}s 持续负载)"
    "realistic|06_realistic_load.sh|真实负载 (60 随机 prompt)"
    "mig|07_mig_isolation.sh|MIG 硬件隔离 (Lambda only)"
)

# ============ 跑测试 ============
echo ""
echo "================================================================"
echo "  Lambda A100 stress test suite"
echo "  endpoint:  ${TEST_ENDPOINT}"
echo "  HPA load:  ${HPA_LOAD_CONCURRENCY} concurrency × ${HPA_LOAD_DURATION}s"
echo "  MIG load:  ${MIG_LOAD_CONCURRENCY} concurrency × ${MIG_LOAD_DURATION}s"
echo "================================================================"
echo ""

START_TS=$(date +%s)

for entry in "${TESTS[@]}"; do
    name="${entry%%|*}"
    rest="${entry#*|}"
    script="${rest%%|*}"
    desc="${rest#*|}"

    if ! should_run "${name}"; then
        log_info "SKIP ${name} (not in $*)"
        continue
    fi

    log_step "${name}: ${desc}"
    if [ ! -x "${SCRIPT_DIR}/${script}" ]; then
        log_warn "  脚本不存在或不可执行: ${script}"
        continue
    fi
    bash "${SCRIPT_DIR}/${script}" || log_warn "  ${name} 退出非零(继续)"
    echo ""
done

END_TS=$(date +%s)
TOTAL_MIN=$(( (END_TS - START_TS) / 60 ))
TOTAL_SEC=$(( (END_TS - START_TS) % 60 ))

# ============ 生成 Lambda-specific SUMMARY.md ============
SUMMARY="${RESULTS_DIR}/SUMMARY.md"

# 读关键指标(每个 sub-test 的 .json)
read_field() {
    local file="$1"; local key="$2"; local default="${3:-?}"
    if [ -f "$file" ]; then
        jq -r ".${key} // \"${default}\"" "$file" 2>/dev/null || echo "${default}"
    else
        echo "${default}"
    fi
}

cat > "${SUMMARY}" <<EOF
# Lambda A100 Stress Test Results

**Date**: $(date '+%F %T %Z')
**Endpoint**: \`${TEST_ENDPOINT}\`
**Total runtime**: ${TOTAL_MIN}m ${TOTAL_SEC}s
**Hardware**: NVIDIA A100 40GB (Lambda Labs) + MIG 7× 1g.5gb
**Model**: \`${TEST_MODEL:-qwen2.5-0.5b}\`

## Summary

| Stage | Status | Headline metric |
|---|---|---|
EOF

# 各阶段一行
for entry in "${TESTS[@]}"; do
    name="${entry%%|*}"
    rest="${entry#*|}"
    script="${rest%%|*}"
    json_name="${script%.sh}.json"
    json_path="${RESULTS_DIR}/${json_name}"

    case "${name}" in
        smoke)
            passed=$(read_field "${json_path}" "passed" "?")
            total=$(read_field "${json_path}" "total" "?")
            echo "| 01 Smoke | ${passed}/${total} passed | functional cases |" >> "${SUMMARY}"
            ;;
        latency)
            p50=$(read_field "${json_path}" "concurrency_8.p50_ms" "?")
            echo "| 02 Latency | done | C8 P50 = ${p50} ms |" >> "${SUMMARY}"
            ;;
        throughput)
            tps=$(read_field "${json_path}" "long_prompt_long_output.output_tok_per_sec" "?")
            echo "| 03 Throughput | done | peak ${tps} tok/s |" >> "${SUMMARY}"
            ;;
        hpa)
            triggered=$(read_field "${json_path}" "hpa_triggered" "?")
            peak=$(read_field "${json_path}" "peak_replicas" "?")
            echo "| 04 HPA | ${triggered} | scaled to **${peak}** replicas |" >> "${SUMMARY}"
            ;;
        stability)
            errs=$(read_field "${json_path}" "errors" "?")
            tot=$(read_field "${json_path}" "total_requests" "?")
            echo "| 05 Stability | done | ${errs}/${tot} errors |" >> "${SUMMARY}"
            ;;
        realistic)
            tps=$(read_field "${json_path}" "output_tok_per_sec" "?")
            p95=$(read_field "${json_path}" "p95_ms" "?")
            echo "| 06 Realistic | done | ${tps} tok/s sustained, P95 ${p95} ms |" >> "${SUMMARY}"
            ;;
        mig)
            verdict=$(read_field "${json_path}" "verdict" "?")
            distinct=$(read_field "${json_path}" "distinct_mig_ids_count" "?")
            echo "| 07 MIG Isolation | ${distinct}/7 MIGs | ${verdict} |" >> "${SUMMARY}"
            ;;
    esac
done

cat >> "${SUMMARY}" <<EOF

## Comparison to Laptop Baseline

The \`telemetry\` branch (RTX 4050 6 GB, GPU time-slicing 2 slots) baseline was:

| Metric | Laptop | Lambda A100 (this run) |
|---|---|---|
| HPA range | 1 ↔ 2 | 1 ↔ 7 |
| Peak throughput | ~824 tok/s | $(read_field "${RESULTS_DIR}/03_throughput.json" "long_prompt_long_output.output_tok_per_sec" "?") tok/s |
| Realistic (random prompts) sustained | ~434 tok/s | $(read_field "${RESULTS_DIR}/06_realistic_load.json" "output_tok_per_sec" "?") tok/s |
| Realistic P95 latency | 5 881 ms | $(read_field "${RESULTS_DIR}/06_realistic_load.json" "p95_ms" "?") ms |
| GPU isolation | software time-slicing | hardware MIG (7 instances) |

Per-stage details: \`${RESULTS_DIR}/0[1-7]_*.json\` and \`*.log\`.

## Files

\`\`\`
$(ls -1 "${RESULTS_DIR}/")
\`\`\`
EOF

echo ""
echo "================================================================"
log_info "✅ All tests done in ${TOTAL_MIN}m ${TOTAL_SEC}s"
log_info "Summary: ${SUMMARY}"
log_info ""
log_info "View it:  cat ${SUMMARY}"
echo "================================================================"
