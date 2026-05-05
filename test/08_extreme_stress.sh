#!/bin/bash
# ================================================================
# 08_extreme_stress.sh — extreme stress test (push GPU to limits)
# ----------------------------------------------------------------
# Goal: drive every available MIG slot to high utilization and force
# HPA all the way up to maxReplicas (7 on Lambda).
#
# Why the existing 04_hpa.sh and 06_realistic_load.sh are not enough:
#   - 04 runs 240s @ concurrency 30. HPA scaleUp policy is "1 pod per
#     120s", so a single 240s window only scales 1→3 in practice.
#   - 06 uses random short prompts. Decode phase is memory-bandwidth
#     bound; Tensor Core utilization stays below 20% even at full load.
#
# This test fixes both:
#   1. concurrency 60 (vs 30) for many minutes — sustained queue depth
#      keeps HPA's `vllm:num_requests_waiting > 5` trigger firing pod
#      after pod until maxReplicas.
#   2. very long prompts (~2000 tokens) so the prefill phase dominates
#      — prefill is compute-bound, exercises the Tensor pipeline at
#      much higher utilization than decode.
#
# Output:
#   08_extreme.log              human-readable timeline
#   08_extreme_timeline.csv     every 15s: replicas, ready, mig_active, peak_gpu
#   08_extreme.json             final summary
# ================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
[ -z "${RESULTS_DIR:-}" ] && { init_results_dir; }

LOG="${RESULTS_DIR}/08_extreme.log"
JSON="${RESULTS_DIR}/08_extreme.json"
TIMELINE="${RESULTS_DIR}/08_extreme_timeline.csv"

# Tunables (env-overridable)
LOAD_DURATION="${EXTREME_LOAD_DURATION:-720}"     # default 12 minutes
LOAD_CONCURRENCY="${EXTREME_LOAD_CONCURRENCY:-60}" # default 60 concurrent
LONG_PROMPT_REPEAT="${EXTREME_PROMPT_REPEAT:-12}"  # ~12x repeat → ~1500-2000 tokens

log_step "08 EXTREME STRESS (saturate 7 MIG + drive HPA to max)"
log_info "endpoint:    ${TEST_ENDPOINT}"
log_info "duration:    ${LOAD_DURATION}s ($((LOAD_DURATION/60)) min)"
log_info "concurrency: ${LOAD_CONCURRENCY}"
log_info "prompt mode: long (×${LONG_PROMPT_REPEAT} repeat → compute-bound prefill)"
echo

# ============ HPA snapshot ============
HPA_MAX=$(kubectl get hpa -n llm vllm-worker -o jsonpath='{.spec.maxReplicas}' 2>/dev/null || echo "?")
INIT_REPLICAS=$(kubectl get deployment -n llm vllm-worker -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
log_info "HPA maxReplicas: ${HPA_MAX}, initial replicas: ${INIT_REPLICAS}"
echo

# ============ Build the long prompt ============
# Combine multiple prompts from the pool into one ~2000-token query.
PROMPTS_FILE="${SCRIPT_DIR}/data/prompts.txt"
LONG_PROMPT=""
if [ -f "${PROMPTS_FILE}" ]; then
    # Take 12 random prompts and concatenate with explicit "Then explain X" framing
    # to prevent vllm from short-circuiting on simple queries.
    for i in $(seq 1 ${LONG_PROMPT_REPEAT}); do
        P=$(shuf -n 1 "${PROMPTS_FILE}")
        LONG_PROMPT="${LONG_PROMPT} ${P}. Explain step by step in detail."
    done
else
    log_warn "prompts.txt not found, using fallback long prompt"
    LONG_PROMPT="Write a comprehensive technical guide covering: distributed systems consensus algorithms (Paxos, Raft), CAP theorem, eventual consistency, vector clocks, Byzantine fault tolerance, blockchain consensus mechanisms, leader election, and the trade-offs between strong and weak consistency. For each topic, provide concrete examples, mathematical formulations where applicable, real-world systems that use them, and discuss the failure modes. Conclude with a comparison table and recommendations for different use cases. The audience is senior engineers."
    for i in $(seq 1 5); do
        LONG_PROMPT="${LONG_PROMPT} ${LONG_PROMPT}"
    done
fi
PROMPT_LEN=${#LONG_PROMPT}
log_info "  long prompt length: ${PROMPT_LEN} chars (~$((PROMPT_LEN/4)) tokens estimated)"
echo

# ============ Background timeline collection ============
{
    echo "timestamp,elapsed_sec,replicas,ready_replicas,active_mig,bindings_count,peak_compute_pct,peak_tensor_pct"
    start_ts=$(date +%s)
    end_ts=$((start_ts + LOAD_DURATION + 60))
    while [ "$(date +%s)" -lt "${end_ts}" ]; do
        now=$(date +%s)
        elapsed=$((now - start_ts))
        replicas=$(kubectl get deployment -n llm vllm-worker -o jsonpath='{.status.replicas}' 2>/dev/null || echo 0)
        ready=$(kubectl get deployment -n llm vllm-worker -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
        active=$(count_active_mig_instances 30s)
        bcount=$(list_mig_pod_bindings | wc -l | tr -d ' ')

        # Peak GPU compute % across all MIG (Prometheus query)
        peak_compute=$(prometheus_query 'max(DCGM_FI_PROF_GR_ENGINE_ACTIVE)' \
                       | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null)
        peak_compute_pct=$(awk -v v="${peak_compute}" 'BEGIN { printf "%.1f", v*100 }')

        peak_tensor=$(prometheus_query 'max(DCGM_FI_PROF_PIPE_TENSOR_ACTIVE)' \
                      | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null)
        peak_tensor_pct=$(awk -v v="${peak_tensor}" 'BEGIN { printf "%.1f", v*100 }')

        echo "$(date '+%F %T'),${elapsed},${replicas},${ready},${active},${bcount},${peak_compute_pct},${peak_tensor_pct}"
        sleep 15
    done
} > "${TIMELINE}" &
TIMELINE_PID=$!
trap "kill ${TIMELINE_PID} 2>/dev/null || true" EXIT

# ============ Run brutal load ============
log_info "==== Starting brutal load (${LOAD_CONCURRENCY} concurrent, long prompts) ===="
load_start_ts=$(date +%s)

# Bigger max_tokens so each request actually does meaningful work
# (small max_tokens = quick decode, doesn't keep GPU busy long enough)
MAX_TOKENS=400

# Pre-build the request body once (jq is expensive in tight loops)
PAYLOAD=$(jq -nc \
    --arg model "${TEST_MODEL}" \
    --arg content "${LONG_PROMPT}" \
    --argjson mt ${MAX_TOKENS} \
    '{model:$model, messages:[{role:"user",content:$content}], max_tokens:$mt}')

(
    pids=()
    end=$((load_start_ts + LOAD_DURATION))
    req_count=0
    last_log=$load_start_ts
    while [ "$(date +%s)" -lt "${end}" ]; do
        # Maintain LOAD_CONCURRENCY active requests
        while [ ${#pids[@]} -lt ${LOAD_CONCURRENCY} ] && [ "$(date +%s)" -lt "${end}" ]; do
            (
                curl -fsS --max-time 90 \
                    -H "Content-Type: application/json" \
                    -X POST -d "${PAYLOAD}" \
                    "${TEST_ENDPOINT}" > /dev/null 2>&1
            ) &
            pids+=($!)
            req_count=$((req_count + 1))
        done
        # Reap finished
        new_pids=()
        for pid in "${pids[@]}"; do
            kill -0 "$pid" 2>/dev/null && new_pids+=("$pid")
        done
        pids=("${new_pids[@]}")

        # Progress log every 30s to stderr so user knows it's alive
        now_ts=$(date +%s)
        if [ $((now_ts - last_log)) -ge 30 ]; then
            echo "[$(date +%H:%M:%S)] in flight=${#pids[@]}, total dispatched=${req_count}, elapsed=$((now_ts - load_start_ts))s/${LOAD_DURATION}s" >&2
            last_log=${now_ts}
        fi

        sleep 0.2
    done
    wait "${pids[@]}" 2>/dev/null || true
    echo "${req_count}" > "${RESULTS_DIR}/.08_req_count"
) &
LOAD_PID=$!

wait ${LOAD_PID} 2>/dev/null || true
load_end_ts=$(date +%s)
load_dur=$((load_end_ts - load_start_ts))
TOTAL_REQS=$(cat "${RESULTS_DIR}/.08_req_count" 2>/dev/null || echo "?")
rm -f "${RESULTS_DIR}/.08_req_count"
log_info "==== Load done in ${load_dur}s, dispatched ${TOTAL_REQS} requests ===="
log_info "==== Observing 60s for HPA scale-down state ===="
sleep 60

kill ${TIMELINE_PID} 2>/dev/null || true
wait ${TIMELINE_PID} 2>/dev/null || true

# ============ Analyze ============
log_info "==== Analysis ===="
PEAK_REPLICAS=$(awk -F, 'NR>1 && $3 ~ /^[0-9]+$/ {if ($3 > m) m = $3} END {print m+0}' "${TIMELINE}")
PEAK_ACTIVE_MIG=$(awk -F, 'NR>1 && $5 ~ /^[0-9]+$/ {if ($5 > m) m = $5} END {print m+0}' "${TIMELINE}")
PEAK_BINDINGS=$(awk -F, 'NR>1 && $6 ~ /^[0-9]+$/ {if ($6 > m) m = $6} END {print m+0}' "${TIMELINE}")
PEAK_COMPUTE=$(awk -F, 'NR>1 {if ($7+0 > m) m = $7+0} END {printf "%.1f", m+0}' "${TIMELINE}")
PEAK_TENSOR=$(awk -F, 'NR>1 {if ($8+0 > m) m = $8+0} END {printf "%.1f", m+0}' "${TIMELINE}")
MEAN_COMPUTE=$(awk -F, 'NR>1 {s+=$7+0; n++} END {if (n) printf "%.1f", s/n; else print "0"}' "${TIMELINE}")
MEAN_TENSOR=$(awk -F, 'NR>1 {s+=$8+0; n++} END {if (n) printf "%.1f", s/n; else print "0"}' "${TIMELINE}")

echo ""
log_info "  HPA peak replicas:        ${PEAK_REPLICAS} / ${HPA_MAX}"
log_info "  peak active MIG count:    ${PEAK_ACTIVE_MIG} / 7"
log_info "  peak MIG↔pod bindings:    ${PEAK_BINDINGS}"
log_info "  peak GPU compute %:       ${PEAK_COMPUTE}%   (mean: ${MEAN_COMPUTE}%)"
log_info "  peak Tensor Core %:       ${PEAK_TENSOR}%   (mean: ${MEAN_TENSOR}%)"
log_info "  total requests:           ${TOTAL_REQS}"

# Verdict
SCORE_HPA="?"
SCORE_MIG="?"
SCORE_GPU="?"
[ "${PEAK_REPLICAS}" -ge 7 ] && SCORE_HPA="✅ MAXED" || \
    { [ "${PEAK_REPLICAS}" -ge 4 ] && SCORE_HPA="🟡 PARTIAL (${PEAK_REPLICAS}/7)" || SCORE_HPA="❌ POOR"; }
[ "${PEAK_BINDINGS}" -ge 7 ] && SCORE_MIG="✅ ALL 7 USED" || \
    { [ "${PEAK_BINDINGS}" -ge 4 ] && SCORE_MIG="🟡 PARTIAL (${PEAK_BINDINGS}/7)" || SCORE_MIG="❌ POOR"; }
PEAK_COMPUTE_INT=$(awk -v v="${PEAK_COMPUTE}" 'BEGIN { printf "%d", v }')
[ "${PEAK_COMPUTE_INT}" -ge 80 ] && SCORE_GPU="✅ HOT" || \
    { [ "${PEAK_COMPUTE_INT}" -ge 50 ] && SCORE_GPU="🟡 WARM" || SCORE_GPU="❄️ COOL"; }

echo ""
log_info "  HPA scaling:    ${SCORE_HPA}"
log_info "  MIG saturation: ${SCORE_MIG}"
log_info "  GPU heat:       ${SCORE_GPU}"

# ============ JSON summary ============
{
    echo "{"
    echo "  \"test\": \"08_extreme_stress\","
    echo "  \"load_duration_sec\": ${load_dur},"
    echo "  \"concurrency\": ${LOAD_CONCURRENCY},"
    echo "  \"prompt_chars\": ${PROMPT_LEN},"
    echo "  \"max_tokens\": ${MAX_TOKENS},"
    echo "  \"total_requests\": \"${TOTAL_REQS}\","
    echo "  \"hpa_max_replicas\": \"${HPA_MAX}\","
    echo "  \"initial_replicas\": ${INIT_REPLICAS},"
    echo "  \"peak_replicas\": ${PEAK_REPLICAS},"
    echo "  \"peak_active_mig_count\": ${PEAK_ACTIVE_MIG},"
    echo "  \"peak_mig_pod_bindings\": ${PEAK_BINDINGS},"
    echo "  \"peak_gpu_compute_percent\": ${PEAK_COMPUTE},"
    echo "  \"mean_gpu_compute_percent\": ${MEAN_COMPUTE},"
    echo "  \"peak_tensor_core_percent\": ${PEAK_TENSOR},"
    echo "  \"mean_tensor_core_percent\": ${MEAN_TENSOR},"
    echo "  \"score_hpa\": \"${SCORE_HPA}\","
    echo "  \"score_mig\": \"${SCORE_MIG}\","
    echo "  \"score_gpu_heat\": \"${SCORE_GPU}\""
    echo "}"
} > "${JSON}"

{
    echo "=== 08 EXTREME STRESS summary ==="
    echo "load:           ${load_dur}s × concurrency ${LOAD_CONCURRENCY}, prompt ${PROMPT_LEN} chars"
    echo "total requests: ${TOTAL_REQS}"
    echo
    echo "HPA peak replicas:    ${PEAK_REPLICAS} / ${HPA_MAX}    [${SCORE_HPA}]"
    echo "MIG saturation:       ${PEAK_BINDINGS} / 7              [${SCORE_MIG}]"
    echo "GPU compute peak:     ${PEAK_COMPUTE}%  (mean ${MEAN_COMPUTE}%)  [${SCORE_GPU}]"
    echo "Tensor Core peak:     ${PEAK_TENSOR}%  (mean ${MEAN_TENSOR}%)"
    echo
    echo "(timeline ${TIMELINE}, every 15s)"
} >> "${LOG}"

log_info "  timeline: ${TIMELINE}"
log_info "  json:     ${JSON}"
