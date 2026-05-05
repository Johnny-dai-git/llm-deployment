#!/bin/bash
# ================================================================
# run_lambda.sh — Lambda A100 / GCP_BRANCH full stress test entry
# ----------------------------------------------------------------
# Differences from run_all.sh:
#   - Auto-detect public IP (from ifconfig.me), set TEST_ENDPOINT
#   - Default parameters tuned for A100 + 7 MIG:
#     · HPA test concurrency 30 (vs laptop 10) —— actually push HPA to 7 replicas
#     · realistic load concurrency 14 (vs 8)    —— 7 MIG × 2
#   - Also run 07_mig_isolation —— only meaningful on Lambda
#   - SUMMARY.md includes vs laptop baseline comparison
#
# Usage:
#   ./run_lambda.sh                 # full suite (~20 min)
#   ./run_lambda.sh smoke latency   # run only specified subset
#
# Environment variables (can override defaults):
#   TEST_ENDPOINT          - default from ifconfig.me
#   HPA_LOAD_CONCURRENCY   - default 30
#   HPA_LOAD_DURATION      - default 240 seconds (enough time for HPA to scale to 7)
#   MIG_LOAD_CONCURRENCY   - default 20 (for test 07)
# ================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============ Auto-detect public IP ============
if [ -z "${TEST_ENDPOINT:-}" ]; then
    PUB_IP=$(curl -fsS --max-time 5 ifconfig.me 2>/dev/null || true)
    if [ -n "$PUB_IP" ]; then
        export TEST_ENDPOINT="http://${PUB_IP}/api/v1/chat/completions"
        echo ">>> Auto-detected public endpoint: ${TEST_ENDPOINT}"
    else
        echo "⚠️  ifconfig.me unreachable, fallback to localhost"
        export TEST_ENDPOINT="http://localhost/api/v1/chat/completions"
    fi
fi

# ============ Lambda tuned default parameters ============
# laptop default → Lambda recommended:
#   HPA_LOAD_CONCURRENCY: 10  → 30
#   HPA_LOAD_DURATION:    180 → 240   (sufficient time for HPA to scale to 7)
#   MIG_LOAD_CONCURRENCY: 20  (new)
#   MIG_LOAD_DURATION:    90  (new)
export HPA_LOAD_CONCURRENCY="${HPA_LOAD_CONCURRENCY:-30}"
export HPA_LOAD_DURATION="${HPA_LOAD_DURATION:-240}"
export MIG_LOAD_CONCURRENCY="${MIG_LOAD_CONCURRENCY:-20}"
export MIG_LOAD_DURATION="${MIG_LOAD_DURATION:-90}"
export STABILITY_DURATION="${STABILITY_DURATION:-300}"

source "${SCRIPT_DIR}/lib/common.sh"

check_deps
check_endpoint
init_results_dir

# ============ Selectively run subset ============
SELECTED=("$@")
should_run() {
    local name="$1"
    [ ${#SELECTED[@]} -eq 0 ] && return 0
    for s in "${SELECTED[@]}"; do
        [ "$s" = "$name" ] && return 0
    done
    return 1
}

# 8 tests, 07 + 08 are Lambda-only
TESTS=(
    "smoke|01_smoke.sh|Functional smoke (7 cases)"
    "latency|02_latency.sh|Latency (concurrency 1/4/8)"
    "throughput|03_throughput.sh|Throughput (4 prompt-output combinations)"
    "hpa|04_hpa.sh|HPA scaling (1↔7 expected on Lambda)"
    "stability|05_stability.sh|Stability (${STABILITY_DURATION}s sustained load)"
    "realistic|06_realistic_load.sh|Realistic load (random prompts)"
    "mig|07_mig_isolation.sh|MIG hardware isolation (Lambda only)"
    "extreme|08_extreme_stress.sh|Extreme stress (drive HPA → 7, push GPU compute %, Lambda only)"
)

# ============ Run tests ============
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
        log_warn "  Script not found or not executable: ${script}"
        continue
    fi
    bash "${SCRIPT_DIR}/${script}" || log_warn "  ${name} exited non-zero (continuing)"
    echo ""
done

END_TS=$(date +%s)
TOTAL_MIN=$(( (END_TS - START_TS) / 60 ))
TOTAL_SEC=$(( (END_TS - START_TS) % 60 ))

# ============ Generate Lambda-specific SUMMARY.md ============
SUMMARY="${RESULTS_DIR}/SUMMARY.md"

# Read key metrics (from each sub-test's .json)
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

# One row per stage
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
| Realistic P95 latency | 5,881 ms | $(read_field "${RESULTS_DIR}/06_realistic_load.json" "p95_ms" "?") ms |
| GPU isolation | software time-slicing | hardware MIG (7 instances) |

Per-stage details: \`${RESULTS_DIR}/0[1-7]_*.json\` and \`*.log\`.

## Files

\`\`\`
$(ls -1 "${RESULTS_DIR}/")
\`\`\`
EOF

echo ""
echo "================================================================"
log_info "✅ All tests complete in ${TOTAL_MIN}m ${TOTAL_SEC}s"
log_info "Summary: ${SUMMARY}"
log_info ""
log_info "View it:  cat ${SUMMARY}"
echo "================================================================"
