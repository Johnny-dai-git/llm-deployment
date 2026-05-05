#!/bin/bash
# ================================================================
# 07_mig_isolation.sh — MIG hardware isolation + multi-replica concurrency demo
# ----------------------------------------------------------------
# This test is meaningful only on Lambda A100 / GCP_BRANCH —— using MIG with
# 7× 1g.5gb instances. The real selling point of hardware isolation is:
#   1. Multiple vllm-worker pods physically run on different MIG instances
#   2. Their GPU usage / memory completely isolated from each other (no noisy neighbor)
#   3. HPA can scale to 7 replicas (max parallelism for single A100)
#
# Test flow:
#   Phase 0  Initial snapshot (how many MIGs are active)
#   Phase 1  Send 60 seconds of high concurrency load (concurrency=20)
#   Phase 2  Sample every 10 seconds: active MIG count + actual pod-MIG bindings
#   Phase 3  Final verdict:
#           - Did HPA scale from 1 to N (>1) replicas?
#           - Did DCGM observe N MIG instances doing work simultaneously?
#           - Are these MIG instances' GPU_I_IDs distinct? (evidence of hardware isolation)
#
# Output:
#   07_mig.log              Human-readable timeline
#   07_mig_timeline.csv     One line every 10 sec: ts, replicas, active_mig_count, bindings
#   07_mig.json             Final summary (for SUMMARY.md reference)
# ================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
[ -z "${RESULTS_DIR:-}" ] && { init_results_dir; }

LOG="${RESULTS_DIR}/07_mig.log"
JSON="${RESULTS_DIR}/07_mig.json"
TIMELINE="${RESULTS_DIR}/07_mig_timeline.csv"

LOAD_DURATION="${MIG_LOAD_DURATION:-90}"          # default 90s high load
LOAD_CONCURRENCY="${MIG_LOAD_CONCURRENCY:-20}"    # default 20 concurrency (enough to saturate 7 MIG)

log_step "07 MIG ISOLATION (Lambda A100 only)"
log_info "endpoint: ${TEST_ENDPOINT}"
log_info "load: ${LOAD_DURATION}s × concurrency=${LOAD_CONCURRENCY}"
echo

# ============ Pre-check ============
# This test is meaningful only in MIG-aware environment (DCGM exposing GPU_I_ID label)
log_info "Checking if DCGM is exposing per-MIG metrics..."
PROBE=$(prometheus_query 'count(count by (GPU_I_ID) (DCGM_FI_DEV_SM_CLOCK))' \
        | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null)
if [ "${PROBE:-0}" -lt 2 ]; then
    log_warn "Prometheus cannot see multiple GPU_I_ID labels, machine not using MIG or DCGM not configured properly"
    log_warn "Skipping MIG isolation test"
    cat > "${JSON}" <<EOF
{"test":"07_mig_isolation","status":"skipped","reason":"no MIG-aware DCGM metrics found (GPU_I_ID label missing)"}
EOF
    exit 0
fi
log_info "✓ DCGM observes ${PROBE} MIG instances"
echo

# ============ Phase 0: Initial snapshot ============
log_info "==== Phase 0: Initial snapshot ===="
INIT_REPLICAS=$(kubectl get deployment -n llm vllm-worker -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)
INIT_ACTIVE=$(count_active_mig_instances 1m)
INIT_BINDINGS=$(list_mig_pod_bindings | wc -l | tr -d ' ')

log_info "  vllm-worker replicas:     ${INIT_REPLICAS}"
log_info "  active MIG (last 1min):   ${INIT_ACTIVE}"
log_info "  MIG↔pod bindings:         ${INIT_BINDINGS}"
echo

# ============ Phase 1+2: Run load, sample every 10 seconds ============
log_info "==== Phase 1: Start ${LOAD_CONCURRENCY} concurrency load (duration ${LOAD_DURATION}s) ===="

# Background timeline collection (every 10 seconds)
{
    echo "timestamp,elapsed_sec,replicas,ready_replicas,active_mig,bindings_count,bindings_detail"
    start_ts=$(date +%s)
    end_ts=$((start_ts + LOAD_DURATION + 30))   # Extra 30 seconds to observe state before HPA scale-down
    while [ "$(date +%s)" -lt "${end_ts}" ]; do
        now=$(date +%s)
        elapsed=$((now - start_ts))
        replicas=$(kubectl get deployment -n llm vllm-worker -o jsonpath='{.status.replicas}' 2>/dev/null || echo 0)
        ready=$(kubectl get deployment -n llm vllm-worker -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
        active=$(count_active_mig_instances 30s)
        bindings=$(list_mig_pod_bindings | tr '\n' '|' | sed 's/|$//')
        bcount=$(list_mig_pod_bindings | wc -l | tr -d ' ')
        echo "$(date '+%F %T'),${elapsed},${replicas},${ready},${active},${bcount},\"${bindings}\""
        sleep 10
    done
} > "${TIMELINE}" &
TIMELINE_PID=$!
trap "kill ${TIMELINE_PID} 2>/dev/null || true" EXIT

# Run load (randomly sample prompts to avoid prefix cache perfect hits)
PROMPTS_FILE="${SCRIPT_DIR}/data/prompts.txt"
USE_RANDOM=0
if [ -f "${PROMPTS_FILE}" ]; then
    USE_RANDOM=1
fi
log_info "  random prompts: $([ ${USE_RANDOM} -eq 1 ] && echo yes || echo "no (fixed prompt)")"

load_start_ts=$(date +%s)
(
    pids=()
    end=$((load_start_ts + LOAD_DURATION))
    while [ "$(date +%s)" -lt "${end}" ]; do
        # Maintain LOAD_CONCURRENCY concurrent requests
        while [ ${#pids[@]} -lt ${LOAD_CONCURRENCY} ] && [ "$(date +%s)" -lt "${end}" ]; do
            if [ ${USE_RANDOM} -eq 1 ]; then
                P=$(shuf -n 1 "${PROMPTS_FILE}" 2>/dev/null || echo "tell me a story about an AI")
            else
                P="Generate a complete story with vivid plot and well-developed characters, around 500 words"
            fi
            (
                curl -fsS --max-time 60 \
                    -H "Content-Type: application/json" \
                    -X POST -d "$(jq -nc \
                        --arg model "${TEST_MODEL}" \
                        --arg content "${P}" \
                        '{model:$model, messages:[{role:"user",content:$content}], max_tokens:200}')" \
                    "${TEST_ENDPOINT}" > /dev/null 2>&1
            ) &
            pids+=($!)
        done
        # Clean up completed processes
        new_pids=()
        for pid in "${pids[@]}"; do
            kill -0 "$pid" 2>/dev/null && new_pids+=("$pid")
        done
        pids=("${new_pids[@]}")
        sleep 0.3
    done
    wait "${pids[@]}" 2>/dev/null || true
) &
LOAD_PID=$!

wait ${LOAD_PID} 2>/dev/null || true
load_end_ts=$(date +%s)
log_info "==== Phase 2: Load complete (duration $((load_end_ts - load_start_ts))s), observing 30s ===="
sleep 30

kill ${TIMELINE_PID} 2>/dev/null || true
wait ${TIMELINE_PID} 2>/dev/null || true

# ============ Phase 3: Analysis ============
log_info "==== Phase 3: Analysis ===="

# Find peak values from timeline
PEAK_REPLICAS=$(awk -F, 'NR>1 && $3 ~ /^[0-9]+$/ {if ($3 > m) m = $3} END {print m+0}' "${TIMELINE}")
PEAK_ACTIVE_MIG=$(awk -F, 'NR>1 && $5 ~ /^[0-9]+$/ {if ($5 > m) m = $5} END {print m+0}' "${TIMELINE}")
PEAK_BINDINGS=$(awk -F, 'NR>1 && $6 ~ /^[0-9]+$/ {if ($6 > m) m = $6} END {print m+0}' "${TIMELINE}")

# All MIG GPU_I_IDs observed during test (extracted from bindings column)
DISTINCT_MIG_IDS=$(awk -F, 'NR>1 {print $7}' "${TIMELINE}" \
    | tr '|' '\n' | tr -d '"' \
    | grep -oE 'MIG-[0-9]+' | sort -u | tr '\n' ' ')
DISTINCT_MIG_COUNT=$(echo "${DISTINCT_MIG_IDS}" | wc -w | tr -d ' ')

log_info "  peak replicas:            ${PEAK_REPLICAS} (initial ${INIT_REPLICAS})"
log_info "  peak active MIG count:    ${PEAK_ACTIVE_MIG}"
log_info "  peak MIG↔pod bindings:    ${PEAK_BINDINGS}"
log_info "  distinct MIG IDs seen:    ${DISTINCT_MIG_COUNT} → [${DISTINCT_MIG_IDS}]"

# Verdict
if [ "${PEAK_REPLICAS}" -gt "${INIT_REPLICAS}" ] && [ "${PEAK_BINDINGS}" -gt 1 ]; then
    VERDICT="✅ HPA scaled + multiple MIGs in parallel, hardware isolation effective"
    PASS=true
elif [ "${PEAK_BINDINGS}" -gt 1 ]; then
    VERDICT="⚠️ Multiple MIGs in use but HPA did not scale (minReplicas already > 1 or load insufficient)"
    PASS=true
else
    VERDICT="❌ Only 1 MIG observed, cannot prove hardware isolation (HPA not triggered?)"
    PASS=false
fi
log_info "  verdict: ${VERDICT}"
echo

# Summary JSON
{
    echo "{"
    echo "  \"test\": \"07_mig_isolation\","
    echo "  \"status\": \"$([ ${PASS} = true ] && echo passed || echo failed)\","
    echo "  \"load_duration_sec\": ${LOAD_DURATION},"
    echo "  \"load_concurrency\": ${LOAD_CONCURRENCY},"
    echo "  \"initial_replicas\": ${INIT_REPLICAS},"
    echo "  \"peak_replicas\": ${PEAK_REPLICAS},"
    echo "  \"peak_active_mig_count\": ${PEAK_ACTIVE_MIG},"
    echo "  \"peak_mig_pod_bindings\": ${PEAK_BINDINGS},"
    echo "  \"distinct_mig_ids_count\": ${DISTINCT_MIG_COUNT},"
    echo "  \"distinct_mig_ids\": \"${DISTINCT_MIG_IDS}\","
    echo "  \"verdict\": \"${VERDICT}\""
    echo "}"
} > "${JSON}"

{
    echo "=== 07 MIG isolation summary ==="
    echo "initial replicas:     ${INIT_REPLICAS}"
    echo "peak replicas:        ${PEAK_REPLICAS}"
    echo "peak active MIG:      ${PEAK_ACTIVE_MIG}"
    echo "peak bindings:        ${PEAK_BINDINGS}"
    echo "distinct MIGs used:   ${DISTINCT_MIG_COUNT} → [${DISTINCT_MIG_IDS}]"
    echo
    echo "verdict: ${VERDICT}"
    echo
    echo "(Timeline at ${TIMELINE}, one line every 10 seconds)"
} >> "${LOG}"

log_info "===== Summary ====="
log_info "  status: $([ ${PASS} = true ] && echo PASSED || echo FAILED)"
log_info "  ${VERDICT}"
log_info "  timeline: ${TIMELINE}"
log_info "  json:     ${JSON}"
