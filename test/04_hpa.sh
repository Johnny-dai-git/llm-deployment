#!/bin/bash
# ================================================================
# 04_hpa.sh — HPA 自动扩容验证
# ----------------------------------------------------------------
# 跑一段持续高负载,观察 HPA 是不是真的能根据指标
# (CPU/memory/custom metrics) 自动扩 vllm-worker 副本数。
# 同时记录 pod 数量和 HPA 决策的时间线。
#
# 输出:
#   04_hpa_timeline.txt — 每 5 秒 snapshot pod count + HPA state
#   04_hpa.json         — 最终汇总(初始/峰值/最终 replicas + HPA 触发情况)
# ================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
[ -z "${RESULTS_DIR:-}" ] && { init_results_dir; }

LOG="${RESULTS_DIR}/04_hpa.log"
JSON="${RESULTS_DIR}/04_hpa.json"
TIMELINE="${RESULTS_DIR}/04_hpa_timeline.txt"

LOAD_DURATION="${HPA_LOAD_DURATION:-180}"   # 持续多久(秒)
LOAD_CONCURRENCY="${HPA_LOAD_CONCURRENCY:-10}"

log_step "04 HPA AUTOSCALING"
log_info "持续 ${LOAD_DURATION}s 的并发 ${LOAD_CONCURRENCY} 推理负载"
log_info "同时每 5 秒记录 pod count + HPA 决策"
echo

# 检查 HPA 是否存在
if ! kubectl get hpa -n llm vllm-worker >/dev/null 2>&1; then
    log_warn "HPA 'vllm-worker' 不存在,跳过此测试"
    log_warn "确认 ArgoCD 同步了 vllm-hpa.yaml"
    cat > "${JSON}" <<EOF
{"test":"04_hpa","status":"skipped","reason":"HPA vllm-worker not found in namespace llm"}
EOF
    exit 0
fi

# 初始状态
INITIAL_REPLICAS=$(kubectl get deployment -n llm vllm-worker -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
INITIAL_HPA_MIN=$(kubectl get hpa -n llm vllm-worker -o jsonpath='{.spec.minReplicas}' 2>/dev/null || echo "?")
INITIAL_HPA_MAX=$(kubectl get hpa -n llm vllm-worker -o jsonpath='{.spec.maxReplicas}' 2>/dev/null || echo "?")
log_info "起始: replicas=${INITIAL_REPLICAS}, HPA range=[${INITIAL_HPA_MIN}..${INITIAL_HPA_MAX}]"

# 后台:每 5 秒 snapshot pod 数 + HPA 状态
{
    echo "timestamp,elapsed_sec,replicas,ready_replicas,hpa_current_metrics,hpa_target,hpa_min,hpa_max"
    start_ts=$(date +%s)
    end_ts=$((start_ts + LOAD_DURATION + 60))   # 多采集 60 秒看缩容
    while [ "$(date +%s)" -lt "${end_ts}" ]; do
        now=$(date +%s)
        elapsed=$((now - start_ts))
        replicas=$(kubectl get deployment -n llm vllm-worker -o jsonpath='{.status.replicas}' 2>/dev/null || echo "?")
        ready=$(kubectl get deployment -n llm vllm-worker -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "?")
        # HPA 字段(可能没有 currentMetrics,jq 处理 null)
        hpa_json=$(kubectl get hpa -n llm vllm-worker -o json 2>/dev/null || echo '{}')
        cur_metric=$(echo "${hpa_json}" | jq -r '.status.currentMetrics[0].resource.current.averageUtilization // .status.currentMetrics[0].pods.current.averageValue // "n/a"' 2>/dev/null)
        target=$(echo "${hpa_json}" | jq -r '.spec.metrics[0].resource.target.averageUtilization // .spec.metrics[0].pods.target.averageValue // "n/a"' 2>/dev/null)
        echo "$(date '+%F %T'),${elapsed},${replicas:-?},${ready:-?},${cur_metric},${target},${INITIAL_HPA_MIN},${INITIAL_HPA_MAX}"
        sleep 5
    done
} > "${TIMELINE}" &
TIMELINE_PID=$!
trap "kill ${TIMELINE_PID} 2>/dev/null || true" EXIT

# 跑负载(后台)
LOAD_PROMPT="写一个完整的故事,要求情节起伏,人物丰满,500 字左右"
log_info "开始跑负载..."
load_start_ts=$(date +%s)
(
    pids=()
    end=$((load_start_ts + LOAD_DURATION))
    while [ "$(date +%s)" -lt "${end}" ]; do
        # 维持 LOAD_CONCURRENCY 个并发请求
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
        # 清理已完成的
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

# 等负载结束
wait ${LOAD_PID} 2>/dev/null || true
load_end_ts=$(date +%s)
log_info "负载结束(用时 $((load_end_ts - load_start_ts))s),再观察 60 秒看 HPA 缩容..."
sleep 60

# 停 timeline
kill ${TIMELINE_PID} 2>/dev/null || true
wait ${TIMELINE_PID} 2>/dev/null || true

# 分析 timeline:看是否扩过容
PEAK_REPLICAS=$(awk -F, 'NR>1 && $3 ~ /^[0-9]+$/ { if ($3 > max) max = $3 } END { print max+0 }' "${TIMELINE}")
FINAL_REPLICAS=$(kubectl get deployment -n llm vllm-worker -o jsonpath='{.status.replicas}' 2>/dev/null || echo "?")

# 判断
if [ "${PEAK_REPLICAS}" -gt "${INITIAL_REPLICAS}" ]; then
    HPA_TRIGGERED="true"
else
    HPA_TRIGGERED="false"
fi

# 写汇总
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
    echo "(timeline 在 ${TIMELINE},每 5 秒一行,可用 column -t -s, 看)"
} >> "${LOG}"

echo
log_info "===== Summary ====="
log_info "  initial replicas: ${INITIAL_REPLICAS}"
log_info "  peak replicas:    ${PEAK_REPLICAS}"
log_info "  final replicas:   ${FINAL_REPLICAS}"
if [ "${HPA_TRIGGERED}" = "true" ]; then
    log_info "  ✅ HPA 成功触发了扩容"
else
    log_warn "  ⚠️  HPA 没扩容(可能负载强度不够 / metrics-server 没就绪 / HPA 阈值过高)"
fi
log_info "  timeline: ${TIMELINE}"
log_info "  json:     ${JSON}"
