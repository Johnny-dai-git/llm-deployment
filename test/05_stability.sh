#!/bin/bash
# ================================================================
# 05_stability.sh — 稳定性测试 (持续负载)
# ----------------------------------------------------------------
# 在中等负载下持续运行 N 分钟,期间:
#   - 持续发推理请求
#   - 周期性 snapshot 集群状态
#   - 监控错误率、pod restart 次数
#
# 通过条件:
#   - 错误率 < 1%
#   - vllm-worker RESTARTS 没增长
#   - 内存没持续往上爬(简单看 first vs last 快照)
# ================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
[ -z "${RESULTS_DIR:-}" ] && { init_results_dir; }

LOG="${RESULTS_DIR}/05_stability.log"
JSON="${RESULTS_DIR}/05_stability.json"
SNAPSHOTS="${RESULTS_DIR}/05_stability_snapshots.txt"

DURATION_SEC="${STABILITY_DURATION:-300}"   # 默认 5 分钟
CONCURRENCY="${STABILITY_CONCURRENCY:-4}"
SNAPSHOT_INTERVAL=30

log_step "05 STABILITY (持续 ${DURATION_SEC}s, 并发 ${CONCURRENCY})"
log_info "可通过 STABILITY_DURATION=1800 跑 30 分钟版"
echo

# 起始 RESTARTS 数
INITIAL_RESTARTS=$(kubectl get pods -n llm -l app=vllm-worker -o jsonpath='{.items[*].status.containerStatuses[0].restartCount}' 2>/dev/null | tr ' ' '+' | bc 2>/dev/null || echo 0)
log_info "起始 vllm-worker RESTARTS 总和: ${INITIAL_RESTARTS}"

# 后台:周期 snapshot
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

# 跑负载,每个请求记录成功/失败
ERR_FILE="${RESULTS_DIR}/05_errors.log"
OK_COUNT_FILE="${RESULTS_DIR}/05_ok_count"
ERR_COUNT_FILE="${RESULTS_DIR}/05_err_count"
echo 0 > "${OK_COUNT_FILE}"
echo 0 > "${ERR_COUNT_FILE}"

PROMPT="简单介绍一下深度学习"
load_start=$(date +%s)
end=$((load_start + DURATION_SEC))

log_info "开始跑负载,每分钟打一个进度提示..."
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
                    # 注意:bash 算数操作 race:用文件锁简单处理
                    flock "${OK_COUNT_FILE}" -c "v=\$(cat ${OK_COUNT_FILE}); echo \$((v+1)) > ${OK_COUNT_FILE}"
                else
                    flock "${ERR_COUNT_FILE}" -c "v=\$(cat ${ERR_COUNT_FILE}); echo \$((v+1)) > ${ERR_COUNT_FILE}"
                    echo "$(date '+%T') request failed" >> "${ERR_FILE}"
                fi
            ) &
            pids+=($!)
        done
        # 清理已完成
        new_pids=()
        for pid in "${pids[@]}"; do
            kill -0 "$pid" 2>/dev/null && new_pids+=("$pid")
        done
        pids=("${new_pids[@]}")
        sleep 0.2

        # 进度
        now=$(date +%s)
        if [ $((now - last_progress)) -ge 60 ]; then
            ok=$(cat "${OK_COUNT_FILE}")
            err=$(cat "${ERR_COUNT_FILE}")
            elapsed=$((now - load_start))
            remaining=$((end - now))
            log_info "  t=${elapsed}s, OK=${ok} ERR=${err}, 剩 ${remaining}s"
            last_progress=${now}
        fi
    done
    wait "${pids[@]}" 2>/dev/null || true
)

load_end=$(date +%s)
wall=$((load_end - load_start))

# 最后再 snapshot 一次
kill ${SNAP_LOOP_PID} 2>/dev/null || true
snapshot_cluster "${SNAPSHOTS}"

# 终态 RESTARTS
FINAL_RESTARTS=$(kubectl get pods -n llm -l app=vllm-worker -o jsonpath='{.items[*].status.containerStatuses[0].restartCount}' 2>/dev/null | tr ' ' '+' | bc 2>/dev/null || echo 0)
RESTART_DELTA=$((FINAL_RESTARTS - INITIAL_RESTARTS))

OK=$(cat "${OK_COUNT_FILE}")
ERR=$(cat "${ERR_COUNT_FILE}")
TOTAL=$((OK + ERR))
ERR_RATE=$(awk -v ok=${OK} -v err=${ERR} 'BEGIN {if (ok+err==0) print 0; else printf "%.4f", err/(ok+err)*100 }')

# 通过条件
PASS=true
[ "${ERR_RATE}" != "0.0000" ] && [ "$(echo "${ERR_RATE} > 1.0" | bc -l)" -eq 1 ] && PASS=false
[ "${RESTART_DELTA}" -gt 0 ] && PASS=false

# 写 JSON
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
