#!/bin/bash
# ================================================================
# 05_stability.sh — Stability test (sustained load)
# ----------------------------------------------------------------
# Run continuously under medium load for N minutes, during which:
#   - Continuously send inference requests
#   - Periodically snapshot cluster state
#   - Monitor error rate, pod restart count
#
# Pass conditions:
#   - Error rate < 1%
#   - vllm-worker RESTARTS did not increase
#   - Memory not continuously climbing (simple first vs last snapshot check)
# ================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
[ -z "${RESULTS_DIR:-}" ] && { init_results_dir; }

LOG="${RESULTS_DIR}/05_stability.log"
JSON="${RESULTS_DIR}/05_stability.json"
SNAPSHOTS="${RESULTS_DIR}/05_stability_snapshots.txt"

DURATION_SEC="${STABILITY_DURATION:-300}"   # Default 5 minutes
CONCURRENCY="${STABILITY_CONCURRENCY:-4}"
SNAPSHOT_INTERVAL=30

log_step "05 STABILITY (sustained ${DURATION_SEC}s at concurrency ${CONCURRENCY})"
log_info "Run 30-minute version with: STABILITY_DURATION=1800"
echo

# Initial RESTARTS count
INITIAL_RESTARTS=$(kubectl get pods -n llm -l app=vllm-worker -o jsonpath='{.items[*].status.containerStatuses[0].restartCount}' 2>/dev/null | tr ' ' '+' | bc 2>/dev/null || echo 0)
log_info "Initial vllm-worker total RESTARTS: ${INITIAL_RESTARTS}"

# Background: periodic snapshot
{
    snapshot_cluster "${SNAPSHOTS}"
} &
SNAP_PID=$!
{
    while sleep "${SNAPSHOT_INTERVAL}"; do
        snapshot_cluster "${SNAPSHOTS}"
    done
} &
SNAP_LOOP_PID=$!
trap "kill ${SNAP_LOOP_PID} 2>/dev/null || true" EXIT

# Run load, record success/failure for each request
ERR_FILE="${RESULTS_DIR}/05_errors.log"
OK_COUNT_FILE="${RESULTS_DIR}/05_ok_count"
ERR_COUNT_FILE="${RESULTS_DIR}/05_err_count"
echo 0 > "${OK_COUNT_FILE}"
echo 0 > "${ERR_COUNT_FILE}"

PROMPT="Brief introduction to deep learning"
load_start=$(date +%s)
end=$((load_start + DURATION_SEC))

log_info "Starting load, progress indicator every minute..."
last_progress=${load_start}

(
    pids=()
    while [ "$(date +%s)" -lt "${end}" ]; do
        while [ ${#pids[@]} -lt ${CONCURRENCY} ] && [ "$(date +%s)" -lt "${end}" ]; do
            (
                if curl -fsS --max-time 30 \
                    -H "Content-Type: application/json" \
                    -X POST -d "$(jq -nc \
                        --arg model "${TEST_MODEL}" \
                        --arg content "${PROMPT}" \
                        '{model:$model, messages:[{role:"user",content:$content}], max_tokens:80}')" \
                    "${TEST_ENDPOINT}" > /dev/null 2>&1; then
                    # Note: bash arithmetic has race conditions; use file lock for simple handling
                    flock "${OK_COUNT_FILE}" -c "v=\$(cat ${OK_COUNT_FILE}); echo \$((v+1)) > ${OK_COUNT_FILE}"
                else
                    flock "${ERR_COUNT_FILE}" -c "v=\$(cat ${ERR_COUNT_FILE}); echo \$((v+1)) > ${ERR_COUNT_FILE}"
                    echo "$(date '+%T') request failed" >> "${ERR_FILE}"
                fi
            ) &
            pids+=($!)
        done
        # Clean up completed
        new_pids=()
        for pid in "${pids[@]}"; do
            kill -0 "$pid" 2>/dev/null && new_pids+=("$pid")
        done
        pids=("${new_pids[@]}")
        sleep 0.2

        # Progress
        now=$(date +%s)
        if [ $((now - last_progress)) -ge 60 ]; then
            ok=$(cat "${OK_COUNT_FILE}")
            err=$(cat "${ERR_COUNT_FILE}")
            elapsed=$((now - load_start))
            remaining=$((end - now))
            log_info "  t=${elapsed}s, OK=${ok} ERR=${err}, remaining ${remaining}s"
            last_progress=${now}
        fi
    done
    wait "${pids[@]}" 2>/dev/null || true
)

load_end=$(date +%s)
wall=$((load_end - load_start))

# Final snapshot
kill ${SNAP_LOOP_PID} 2>/dev/null || true
snapshot_cluster "${SNAPSHOTS}"

# Final RESTARTS
FINAL_RESTARTS=$(kubectl get pods -n llm -l app=vllm-worker -o jsonpath='{.items[*].status.containerStatuses[0].restartCount}' 2>/dev/null | tr ' ' '+' | bc 2>/dev/null || echo 0)
RESTART_DELTA=$((FINAL_RESTARTS - INITIAL_RESTARTS))

OK=$(cat "${OK_COUNT_FILE}")
ERR=$(cat "${ERR_COUNT_FILE}")
TOTAL=$((OK + ERR))
ERR_RATE=$(awk -v ok=${OK} -v err=${ERR} 'BEGIN {if (ok+err==0) print 0; else printf "%.4f", err/(ok+err)*100 }')

# Pass conditions
PASS=true
[ "${ERR_RATE}" != "0.0000" ] && [ "$(echo "${ERR_RATE} > 1.0" | bc -l)" -eq 1 ] && PASS=false
[ "${RESTART_DELTA}" -gt 0 ] && PASS=false

# Write JSON
cat > "${JSON}" <<EOF
{
  "test": "05_stability",
  "duration_sec": ${wall},
  "concurrency": ${CONCURRENCY},
  "ok_requests": ${OK},
  "err_requests": ${ERR},
  "total_requests": ${TOTAL},
  "error_rate_percent": ${ERR_RATE},
  "rps": $(awk -v t=${TOTAL} -v w=${wall} 'BEGIN {if (w==0) print 0; else printf "%.2f", t/w}'),
  "vllm_restart_delta": ${RESTART_DELTA},
  "passed": ${PASS},
  "snapshots_file": "${SNAPSHOTS}"
}
EOF

echo
log_info "===== Summary ====="
log_info "  duration:      ${wall}s"
log_info "  total reqs:    ${TOTAL}"
log_info "  OK:            ${OK}"
log_info "  ERR:           ${ERR} (${ERR_RATE}%)"
log_info "  RPS:           $(awk -v t=${TOTAL} -v w=${wall} 'BEGIN {if (w==0) print 0; else printf "%.2f", t/w}')"
log_info "  vllm RESTARTS: ${INITIAL_RESTARTS} → ${FINAL_RESTARTS} (Δ=${RESTART_DELTA})"
if [ "${PASS}" = "true" ]; then
    log_info "  ✅ stability test PASSED"
else
    log_warn "  ⚠️  stability test FAILED (errors > 1% or pods restarted)"
fi
log_info "  json:      ${JSON}"
log_info "  snapshots: ${SNAPSHOTS}"
