#!/bin/bash
# ================================================================
# run_all.sh — One-command run all tests
# ----------------------------------------------------------------
# Execute sequentially: 01_smoke → 02_latency → 03_throughput → 04_hpa → 05_stability,
# all results go to ./results/<timestamp>/, finally generate SUMMARY.md.
#
# Usage:
#   ./run_all.sh                                  # Run full suite (default ~10 min)
#   ./run_all.sh smoke latency                    # Run only specified subset
#
# Environment variables:
#   TEST_ENDPOINT  - LLM API address (default http://localhost/api/v1/chat/completions)
#   TEST_MODEL     - Model name (default qwen2.5-0.5b)
#   STABILITY_DURATION - 05 stability test duration (seconds, default 300)
#   HPA_LOAD_DURATION  - 04 HPA test duration (seconds, default 180)
# ================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

check_deps
check_endpoint

# Initialize results directory (shared by subsequent sub-scripts)
init_results_dir

# Selectively run subset
SELECTED=("$@")
ALL=(smoke latency throughput hpa stability realistic)
[ ${#SELECTED[@]} -eq 0 ] && SELECTED=("${ALL[@]}")

START_TS=$(date +%s)

log_step "RUN ALL TESTS"
log_info "Selected tests: ${SELECTED[*]}"
log_info "Results dir:    ${RESULTS_DIR}"
log_info "Tip: Ctrl+C to interrupt, completed test results will be preserved"
echo

# Initial cluster snapshot
snapshot_cluster "${RESULTS_DIR}/00_initial_cluster.txt"

declare -A TEST_STATUS

run_one() {
    local key="$1"
    local script="${SCRIPT_DIR}/$2"
    log_info "▶ Running ${script##*/}"
    if [ ! -x "${script}" ]; then
        log_error "${script} does not exist or not executable"
        TEST_STATUS[${key}]="missing"
        return
    fi
    if "${script}"; then
        TEST_STATUS[${key}]="ok"
    else
        TEST_STATUS[${key}]="failed"
        log_warn "  ${script##*/} exited non-zero, continuing with remaining tests"
    fi
    echo
}

[[ " ${SELECTED[*]} " =~ " smoke "      ]] && run_one smoke      01_smoke.sh
[[ " ${SELECTED[*]} " =~ " latency "    ]] && run_one latency    02_latency.sh
[[ " ${SELECTED[*]} " =~ " throughput " ]] && run_one throughput 03_throughput.sh
[[ " ${SELECTED[*]} " =~ " hpa "        ]] && run_one hpa        04_hpa.sh
[[ " ${SELECTED[*]} " =~ " stability "  ]] && run_one stability  05_stability.sh
[[ " ${SELECTED[*]} " =~ " realistic "  ]] && run_one realistic  06_realistic_load.sh

# Final cluster snapshot
snapshot_cluster "${RESULTS_DIR}/99_final_cluster.txt"

END_TS=$(date +%s)
TOTAL_SEC=$((END_TS - START_TS))

# ========== Generate SUMMARY.md ==========
SUMMARY="${RESULTS_DIR}/SUMMARY.md"

# helper: jq read json field, return N/A on failure
jq_or_na() {
    local file="$1" path="$2"
    [ -f "${file}" ] && jq -r "${path} // \"N/A\"" "${file}" 2>/dev/null || echo "N/A"
}

{
    echo "# Test Run Summary"
    echo
    echo "- **Started**:   $(date -d @${START_TS} '+%F %T')"
    echo "- **Finished**:  $(date -d @${END_TS} '+%F %T')"
    echo "- **Duration**:  ${TOTAL_SEC}s"
    echo "- **Endpoint**:  \`${TEST_ENDPOINT}\`"
    echo "- **Model**:     \`${TEST_MODEL}\`"
    echo "- **Results**:   \`$(realpath --relative-to="${SCRIPT_DIR}" "${RESULTS_DIR}")\`"
    echo
    echo "## Status"
    echo
    for key in smoke latency throughput hpa stability realistic; do
        s="${TEST_STATUS[$key]:-skipped}"
        case "${s}" in
            ok)      icon="✅" ;;
            failed)  icon="❌" ;;
            missing) icon="⚠️ " ;;
            skipped) icon="⏭️ " ;;
        esac
        echo "- ${icon} \`${key}\` — ${s}"
    done
    echo

    # ========== 01 smoke ==========
    if [ -f "${RESULTS_DIR}/01_smoke.json" ]; then
        echo "## 01 — Functional"
        echo
        pass=$(jq_or_na "${RESULTS_DIR}/01_smoke.json" .pass)
        fail=$(jq_or_na "${RESULTS_DIR}/01_smoke.json" .fail)
        total=$(jq_or_na "${RESULTS_DIR}/01_smoke.json" .total)
        echo "- pass / total: **${pass} / ${total}**"
        [ "${fail}" != "0" ] && [ "${fail}" != "N/A" ] && echo "- ❌ failures: ${fail}"
        echo
        echo "Per-case:"
        echo
        jq -r '.cases[] | "- \(if .result == "PASS" then "✅" else "❌" end) `\(.name)`"' "${RESULTS_DIR}/01_smoke.json" 2>/dev/null || true
        echo
    fi

    # ========== 02 latency ==========
    if [ -f "${RESULTS_DIR}/02_latency.json" ]; then
        echo "## 02 — Latency (ms)"
        echo
        echo "| concurrency | requests | mean | P50 | P90 | P95 | P99 |"
        echo "|---|---|---|---|---|---|---|"
        for c in 1 4 8; do
            cnt=$(jq_or_na "${RESULTS_DIR}/02_latency.json" ".results.c${c}.count")
            mean=$(jq_or_na "${RESULTS_DIR}/02_latency.json" ".results.c${c}.mean_ms")
            p50=$(jq_or_na "${RESULTS_DIR}/02_latency.json" ".results.c${c}.p50_ms")
            p90=$(jq_or_na "${RESULTS_DIR}/02_latency.json" ".results.c${c}.p90_ms")
            p95=$(jq_or_na "${RESULTS_DIR}/02_latency.json" ".results.c${c}.p95_ms")
            p99=$(jq_or_na "${RESULTS_DIR}/02_latency.json" ".results.c${c}.p99_ms")
            echo "| ${c} | ${cnt} | ${mean} | ${p50} | ${p90} | ${p95} | ${p99} |"
        done
        echo
    fi

    # ========== 03 throughput ==========
    if [ -f "${RESULTS_DIR}/03_throughput.json" ]; then
        echo "## 03 — Throughput (output token/s)"
        echo
        echo "| scenario | requests | concurrency | wall (s) | output tok/s | avg latency (ms) |"
        echo "|---|---|---|---|---|---|"
        for sc in short_short short_long long_short long_long; do
            cnt=$(jq_or_na "${RESULTS_DIR}/03_throughput.json" ".scenarios.${sc}.requests")
            conc=$(jq_or_na "${RESULTS_DIR}/03_throughput.json" ".scenarios.${sc}.concurrency")
            wall=$(jq_or_na "${RESULTS_DIR}/03_throughput.json" ".scenarios.${sc}.wall_sec")
            tps=$(jq_or_na "${RESULTS_DIR}/03_throughput.json" ".scenarios.${sc}.output_tok_per_sec")
            avg=$(jq_or_na "${RESULTS_DIR}/03_throughput.json" ".scenarios.${sc}.avg_latency_ms")
            echo "| ${sc} | ${cnt} | ${conc} | ${wall} | ${tps} | ${avg} |"
        done
        echo
    fi

    # ========== 04 hpa ==========
    if [ -f "${RESULTS_DIR}/04_hpa.json" ]; then
        echo "## 04 — HPA Autoscaling"
        echo
        status=$(jq_or_na "${RESULTS_DIR}/04_hpa.json" .status)
        if [ "${status}" = "skipped" ]; then
            echo "_skipped: HPA 'vllm-worker' not found_"
        else
            init=$(jq_or_na "${RESULTS_DIR}/04_hpa.json" .initial_replicas)
            peak=$(jq_or_na "${RESULTS_DIR}/04_hpa.json" .peak_replicas)
            final=$(jq_or_na "${RESULTS_DIR}/04_hpa.json" .final_replicas)
            triggered=$(jq_or_na "${RESULTS_DIR}/04_hpa.json" .hpa_triggered)
            min=$(jq_or_na "${RESULTS_DIR}/04_hpa.json" .hpa_min)
            max=$(jq_or_na "${RESULTS_DIR}/04_hpa.json" .hpa_max)
            echo "- HPA range: \`[${min} .. ${max}]\`"
            echo "- replicas: initial=${init}, **peak=${peak}**, final=${final}"
            if [ "${triggered}" = "true" ]; then
                echo "- ✅ HPA successfully triggered scale-up"
            else
                echo "- ⚠️  HPA did not scale (insufficient load / metrics not ready / threshold too high)"
            fi
            echo
            echo "Timeline in \`04_hpa_timeline.txt\` (one line every 5 seconds)."
        fi
        echo
    fi

    # ========== 05 stability ==========
    if [ -f "${RESULTS_DIR}/05_stability.json" ]; then
        echo "## 05 — Stability"
        echo
        d=$(jq_or_na "${RESULTS_DIR}/05_stability.json" .duration_sec)
        ok=$(jq_or_na "${RESULTS_DIR}/05_stability.json" .ok_requests)
        err=$(jq_or_na "${RESULTS_DIR}/05_stability.json" .err_requests)
        rate=$(jq_or_na "${RESULTS_DIR}/05_stability.json" .error_rate_percent)
        rps=$(jq_or_na "${RESULTS_DIR}/05_stability.json" .rps)
        delta=$(jq_or_na "${RESULTS_DIR}/05_stability.json" .vllm_restart_delta)
        passed=$(jq_or_na "${RESULTS_DIR}/05_stability.json" .passed)
        echo "- duration: ${d}s"
        echo "- requests: OK=${ok}  ERR=${err}  (rate=${rate}%)"
        echo "- RPS: ${rps}"
        echo "- vllm-worker RESTARTS Δ: ${delta}"
        if [ "${passed}" = "true" ]; then
            echo "- ✅ stability **PASSED**"
        else
            echo "- ❌ stability **FAILED** (errors > 1% or pods restarted)"
        fi
        echo
    fi

    # ========== 06 realistic ==========
    if [ -f "${RESULTS_DIR}/06_realistic.json" ]; then
        echo "## 06 — Realistic Load (random prompts, no prefix-cache speedup)"
        echo
        d=$(jq_or_na "${RESULTS_DIR}/06_realistic.json" .duration_sec)
        conc=$(jq_or_na "${RESULTS_DIR}/06_realistic.json" .concurrency)
        pool=$(jq_or_na "${RESULTS_DIR}/06_realistic.json" .prompt_pool_size)
        ok=$(jq_or_na "${RESULTS_DIR}/06_realistic.json" .ok_requests)
        err=$(jq_or_na "${RESULTS_DIR}/06_realistic.json" .err_requests)
        rate=$(jq_or_na "${RESULTS_DIR}/06_realistic.json" .error_rate_percent)
        rps=$(jq_or_na "${RESULTS_DIR}/06_realistic.json" .rps)
        echo "- duration: ${d}s, concurrency: ${conc}, prompt pool: ${pool}"
        echo "- OK=${ok}  ERR=${err}  (rate=${rate}%, RPS=${rps})"
        echo
        echo "**Overall latency (ms):**"
        echo "| count | min | max | mean | P50 | P90 | P95 | P99 |"
        echo "|---|---|---|---|---|---|---|---|"
        cnt=$(jq_or_na "${RESULTS_DIR}/06_realistic.json" .latency_ms_overall.count)
        mn=$(jq_or_na "${RESULTS_DIR}/06_realistic.json" .latency_ms_overall.min_ms)
        mx=$(jq_or_na "${RESULTS_DIR}/06_realistic.json" .latency_ms_overall.max_ms)
        me=$(jq_or_na "${RESULTS_DIR}/06_realistic.json" .latency_ms_overall.mean_ms)
        p50=$(jq_or_na "${RESULTS_DIR}/06_realistic.json" .latency_ms_overall.p50_ms)
        p90=$(jq_or_na "${RESULTS_DIR}/06_realistic.json" .latency_ms_overall.p90_ms)
        p95=$(jq_or_na "${RESULTS_DIR}/06_realistic.json" .latency_ms_overall.p95_ms)
        p99=$(jq_or_na "${RESULTS_DIR}/06_realistic.json" .latency_ms_overall.p99_ms)
        echo "| ${cnt} | ${mn} | ${mx} | ${me} | ${p50} | ${p90} | ${p95} | ${p99} |"
        echo
        echo "**Latency P50/P95 grouped by prompt length (ms):**"
        echo "| bucket | count | P50 | P95 |"
        echo "|---|---|---|---|"
        for b in short medium long; do
            c=$(jq_or_na "${RESULTS_DIR}/06_realistic.json" ".latency_ms_by_prompt_size.${b}.count")
            p50_b=$(jq_or_na "${RESULTS_DIR}/06_realistic.json" ".latency_ms_by_prompt_size.${b}.p50_ms")
            p95_b=$(jq_or_na "${RESULTS_DIR}/06_realistic.json" ".latency_ms_by_prompt_size.${b}.p95_ms")
            echo "| ${b} | ${c} | ${p50_b} | ${p95_b} |"
        done
        echo
        echo "**Token throughput (based on wall time):**"
        op=$(jq_or_na "${RESULTS_DIR}/06_realistic.json" .token_throughput.output_tok_per_sec)
        tp=$(jq_or_na "${RESULTS_DIR}/06_realistic.json" .token_throughput.total_tok_per_sec)
        echo "- output tok/s: **${op}**"
        echo "- total tok/s (including prompt): ${tp}"
        echo
    fi

    echo "---"
    echo
    echo "## File List"
    echo
    cd "${RESULTS_DIR}" && ls -1 | sed 's|^|- `|; s|$|`|'
} > "${SUMMARY}"

echo
log_step "DONE"
log_info "Total runtime: ${TOTAL_SEC}s"
log_info "Results:      ${RESULTS_DIR}"
log_info "Summary:      ${SUMMARY}"
echo
echo "View summary:"
echo "  cat ${SUMMARY}"
echo "  glow ${SUMMARY}     # if installed, renders prettier"
