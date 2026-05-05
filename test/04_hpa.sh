#!/bin/bash
# ================================================================
# 04_hpa.sh — HPA auto-scaling verification
# ----------------------------------------------------------------
# Run sustained high load and observe whether HPA can automatically
# scale vllm-worker replicas based on metrics (CPU/memory/custom).
# Record pod count and HPA decision timeline simultaneously.
#
# Output:
#   04_hpa_timeline.txt — pod count + HPA state snapshot every 5 sec
#   04_hpa.json         — final summary (initial/peak/final replicas + HPA trigger status)
# ================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
[ -z "${RESULTS_DIR:-}" ] && { init_results_dir; }

LOG="${RESULTS_DIR}/04_hpa.log"
JSON="${RESULTS_DIR}/04_hpa.json"
TIMELINE="${RESULTS_DIR}/04_hpa_timeline.txt"

LOAD_DURATION="${HPA_LOAD_DURATION:-180}"   # Duration (seconds)
LOAD_CONCURRENCY="${HPA_LOAD_CONCURRENCY:-10}"

log_step "04 HPA AUTOSCALING"
log_info "Sustained high load: ${LOAD_DURATION}s at concurrency ${LOAD_CONCURRENCY}"
log_info "Record pod count + HPA decision every 5 seconds"
echo

# Check if HPA exists
if ! kubectl get hpa -n llm vllm-worker >/dev/null 2>&1; then
    log_warn "HPA 'vllm-worker' not found, skipping this test"
    log_warn "Confirm that ArgoCD synced vllm-hpa.yaml"
    cat > "${JSON}" <<EOF
{"test":"04_hpa","status":"skipped","reason":"HPA vllm-worker not found in namespace llm"}
EOF
    exit 0
fi

# Initial state
INITIAL_REPLICAS=$(kubectl get deployment -n llm vllm-worker -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
INITIAL_HPA_MIN=$(kubectl get hpa -n llm vllm-worker -o jsonpath='{.spec.minReplicas}' 2>/dev/null || echo "?")
INITIAL_HPA_MAX=$(kubectl get hpa -n llm vllm-worker -o jsonpath='{.spec.maxReplicas}' 2>/dev/null || echo "?")
log_info "Initial: replicas=${INITIAL_REPLICAS}, HPA range=[${INITIAL_HPA_MIN}..${INITIAL_HPA_MAX}]"

# Background: snapshot pod count + HPA state every 5 seconds
{
    echo "timestamp,elapsed_sec,replicas,ready_replicas,hpa_current_metrics,hpa_target,hpa_min,hpa_max"
    start_ts=$(date +%s)
    end_ts=$((start_ts + LOAD_DURATION + 60))   # Collect 60 extra seconds to observe scale-down
    while [ "$(date +%s)" -lt "${end_ts}" ]; do
        now=$(date +%s)
        elapsed=$((now - start_ts))
        replicas=$(kubectl get deployment -n llm vllm-worker -o jsonpath='{.status.replicas}' 2>/dev/null || echo "?")
        ready=$(kubectl get deployment -n llm vllm-worker -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "?")
        # HPA fields (currentMetrics may not exist, jq handles null)
        hpa_json=$(kubectl get hpa -n llm vllm-worker -o json 2>/dev/null || echo '{}')
        cur_metric=$(echo "${hpa_json}" | jq -r '.status.currentMetrics[0].resource.current.averageUtilization // .status.currentMetrics[0].pods.current.averageValue // "n/a"' 2>/dev/null)
        target=$(echo "${hpa_json}" | jq -r '.spec.metrics[0].resource.target.averageUtilization // .spec.metrics[0].pods.target.averageValue // "n/a"' 2>/dev/null)
        echo "$(date '+%F %T'),${elapsed},${replicas:-?},${ready:-?},${cur_metric},${target},${INITIAL_HPA_MIN},${INITIAL_HPA_MAX}"
        sleep 5
    done
} > "${TIMELINE}" &
TIMELINE_PID=$!
trap "kill ${TIMELINE_PID} 2>/dev/null || true" EXIT

# Run load (background)
LOAD_PROMPT="Write a complete story with vivid plot and well-developed characters, around 500 words"
log_info "Starting load..."
load_start_ts=$(date +%s)
(
    pids=()
    end=$((load_start_ts + LOAD_DURATION))
    while [ "$(date +%s)" -lt "${end}" ]; do
        # Maintain LOAD_CONCURRENCY concurrent requests
        while [ ${#pids[@]} -lt ${LOAD_CONCURRENCY} ] && [ "$(date +%s)" -lt "${end}" ]; do
            (
                curl -fsS --max-time 60 \
                    -H "Content-Type: application/json" \
                    -X POST -d "$(jq -nc \
                        --arg model "${TEST_MODEL}" \
                        --arg content "${LOAD_PROMPT}" \
                        '{model:$model, messages:[{role:"user",content:$content}], max_tokens:300}')" \
                    "${TEST_ENDPOINT}" > /dev/null 2>&1
            ) &
            pids+=($!)
        done
        # Clean up completed requests
        new_pids=()
        for pid in "${pids[@]}"; do
            kill -0 "$pid" 2>/dev/null && new_pids+=("$pid")
        done
        pids=("${new_pids[@]}")
        sleep 0.5
    done
    wait "${pids[@]}" 2>/dev/null || true
) &
LOAD_PID=$!

# Wait for load to finish
wait ${LOAD_PID} 2>/dev/null || true
load_end_ts=$(date +%s)
log_info "Load complete (duration $((load_end_ts - load_start_ts))s), observing 60 seconds for scale-down..."
sleep 60

# Stop timeline
kill ${TIMELINE_PID} 2>/dev/null || true
wait ${TIMELINE_PID} 2>/dev/null || true

# Analyze timeline: check if scaled up
PEAK_REPLICAS=$(awk -F, 'NR>1 && $3 ~ /^[0-9]+$/ { if ($3 > max) max = $3 } END { print max+0 }' "${TIMELINE}")
FINAL_REPLICAS=$(kubectl get deployment -n llm vllm-worker -o jsonpath='{.status.replicas}' 2>/dev/null || echo "?")

# Determine if HPA triggered
if [ "${PEAK_REPLICAS}" -gt "${INITIAL_REPLICAS}" ]; then
    HPA_TRIGGERED="true"
else
    HPA_TRIGGERED="false"
fi

# Write summary
{
    echo "{"
    echo "  \"test\": \"04_hpa\","
    echo "  \"load_duration_sec\": ${LOAD_DURATION},"
    echo "  \"load_concurrency\": ${LOAD_CONCURRENCY},"
    echo "  \"initial_replicas\": ${INITIAL_REPLICAS},"
    echo "  \"peak_replicas\": ${PEAK_REPLICAS},"
    echo "  \"final_replicas\": \"${FINAL_REPLICAS}\","
    echo "  \"hpa_min\": \"${INITIAL_HPA_MIN}\","
    echo "  \"hpa_max\": \"${INITIAL_HPA_MAX}\","
    echo "  \"hpa_triggered\": ${HPA_TRIGGERED},"
    echo "  \"timeline_file\": \"${TIMELINE}\""
    echo "}"
} > "${JSON}"

{
    echo "=== HPA test summary ==="
    echo "initial_replicas: ${INITIAL_REPLICAS}"
    echo "peak_replicas:    ${PEAK_REPLICAS}"
    echo "final_replicas:   ${FINAL_REPLICAS}"
    echo "hpa_triggered:    ${HPA_TRIGGERED}"
    echo
    echo "(Timeline at ${TIMELINE}, one line every 5 seconds, use: column -t -s, to view)"
} >> "${LOG}"

echo
log_info "===== Summary ====="
log_info "  initial replicas: ${INITIAL_REPLICAS}"
log_info "  peak replicas:    ${PEAK_REPLICAS}"
log_info "  final replicas:   ${FINAL_REPLICAS}"
if [ "${HPA_TRIGGERED}" = "true" ]; then
    log_info "  ✅ HPA successfully triggered scale-up"
else
    log_warn "  ⚠️  HPA did not scale up (load too light / metrics-server not ready / HPA threshold too high)"
fi
log_info "  timeline: ${TIMELINE}"
log_info "  json:     ${JSON}"
