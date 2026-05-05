#!/bin/bash
# ================================================================
# 07_mig_isolation.sh — MIG 硬件隔离 + 多副本并发演示
# ----------------------------------------------------------------
# 这是 Lambda A100 / GCP_BRANCH 才有意义的测试 —— 用 MIG 7 个 1g.5gb
# 实例做硬件隔离的真正卖点在于:
#   1. 多个 vllm-worker pod 物理上跑在不同 MIG 实例上
#   2. 它们的 GPU 用量 / 内存彼此完全隔离 (no noisy neighbor)
#   3. HPA 可以扩到 7 副本(单 A100 的最大并行度)
#
# 测试流程:
#   阶段 0  起始快照 (有几个 MIG 在跑 work)
#   阶段 1  打 60 秒高并发负载 (concurrency=20)
#   阶段 2  每 10 秒采一次 active MIG count + 实际 pod-MIG 绑定
#   阶段 3  最终判断:
#           - HPA 是不是从 1 扩到了 N (>1) 副本
#           - DCGM 是不是看到 N 个 MIG 实例同时在干活
#           - 这些 MIG 实例的 GPU_I_ID 是不是 distinct (硬件隔离证据)
#
# 输出:
#   07_mig.log              人类可读 timeline
#   07_mig_timeline.csv     每 10 秒一行: ts, replicas, active_mig_count, bindings
#   07_mig.json             最终汇总 (供 SUMMARY.md 引用)
# ================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
[ -z "${RESULTS_DIR:-}" ] && { init_results_dir; }

LOG="${RESULTS_DIR}/07_mig.log"
JSON="${RESULTS_DIR}/07_mig.json"
TIMELINE="${RESULTS_DIR}/07_mig_timeline.csv"

LOAD_DURATION="${MIG_LOAD_DURATION:-90}"          # 默认 90s 高负载
LOAD_CONCURRENCY="${MIG_LOAD_CONCURRENCY:-20}"    # 默认 20 并发(吃满 7 MIG 够了)

log_step "07 MIG ISOLATION (Lambda A100 only)"
log_info "endpoint: ${TEST_ENDPOINT}"
log_info "load: ${LOAD_DURATION}s × concurrency=${LOAD_CONCURRENCY}"
echo

# ============ 前置检查 ============
# 这个测试只在 MIG-aware 环境(DCGM 暴露 GPU_I_ID label)有意义。
log_info "检查 DCGM 是否在暴露 per-MIG 指标..."
PROBE=$(prometheus_query 'count(count by (GPU_I_ID) (DCGM_FI_DEV_SM_CLOCK))' \
        | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null)
if [ "${PROBE:-0}" -lt 2 ]; then
    log_warn "Prometheus 看不到多个 GPU_I_ID label,这台机器没用 MIG 或 DCGM 没装好"
    log_warn "跳过 MIG isolation 测试"
    cat > "${JSON}" <<EOF
{"test":"07_mig_isolation","status":"skipped","reason":"no MIG-aware DCGM metrics found (GPU_I_ID label missing)"}
EOF
    exit 0
fi
log_info "✓ DCGM 看到 ${PROBE} 个 MIG 实例"
echo

# ============ 阶段 0: 起始快照 ============
log_info "==== 阶段 0: 起始快照 ===="
INIT_REPLICAS=$(kubectl get deployment -n llm vllm-worker -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)
INIT_ACTIVE=$(count_active_mig_instances 1m)
INIT_BINDINGS=$(list_mig_pod_bindings | wc -l | tr -d ' ')

log_info "  vllm-worker replicas:     ${INIT_REPLICAS}"
log_info "  active MIG (last 1min):   ${INIT_ACTIVE}"
log_info "  MIG↔pod bindings:         ${INIT_BINDINGS}"
echo

# ============ 阶段 1+2: 跑负载,每 10 秒采样 ============
log_info "==== 阶段 1: 启动 ${LOAD_CONCURRENCY} 并发负载 (持续 ${LOAD_DURATION}s) ===="

# 后台 timeline 采集 (每 10 秒)
{
    echo "timestamp,elapsed_sec,replicas,ready_replicas,active_mig,bindings_count,bindings_detail"
    start_ts=$(date +%s)
    end_ts=$((start_ts + LOAD_DURATION + 30))   # 多 30 秒看 HPA 缩容前的状态
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

# 跑负载 (随机选 prompt 避免 prefix cache 全命中)
PROMPTS_FILE="${SCRIPT_DIR}/data/prompts.txt"
USE_RANDOM=0
if [ -f "${PROMPTS_FILE}" ]; then
    USE_RANDOM=1
fi
log_info "  随机 prompt: $([ ${USE_RANDOM} -eq 1 ] && echo yes || echo "no (固定 prompt)")"

load_start_ts=$(date +%s)
(
    pids=()
    end=$((load_start_ts + LOAD_DURATION))
    while [ "$(date +%s)" -lt "${end}" ]; do
        # 维持 LOAD_CONCURRENCY 个并发
        while [ ${#pids[@]} -lt ${LOAD_CONCURRENCY} ] && [ "$(date +%s)" -lt "${end}" ]; do
            if [ ${USE_RANDOM} -eq 1 ]; then
                P=$(shuf -n 1 "${PROMPTS_FILE}" 2>/dev/null || echo "tell me a story about an AI")
            else
                P="生成一个完整的故事,要求情节起伏,人物丰满,500 字左右"
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
        # 清理已完成的
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
log_info "==== 阶段 2: 负载结束 (用时 $((load_end_ts - load_start_ts))s),再观察 30s ===="
sleep 30

kill ${TIMELINE_PID} 2>/dev/null || true
wait ${TIMELINE_PID} 2>/dev/null || true

# ============ 阶段 3: 分析 ============
log_info "==== 阶段 3: 分析 ===="

# 从 timeline 找峰值
PEAK_REPLICAS=$(awk -F, 'NR>1 && $3 ~ /^[0-9]+$/ {if ($3 > m) m = $3} END {print m+0}' "${TIMELINE}")
PEAK_ACTIVE_MIG=$(awk -F, 'NR>1 && $5 ~ /^[0-9]+$/ {if ($5 > m) m = $5} END {print m+0}' "${TIMELINE}")
PEAK_BINDINGS=$(awk -F, 'NR>1 && $6 ~ /^[0-9]+$/ {if ($6 > m) m = $6} END {print m+0}' "${TIMELINE}")

# 测试期间所有出现过的 MIG GPU_I_ID(从 bindings 列里抽出)
DISTINCT_MIG_IDS=$(awk -F, 'NR>1 {print $7}' "${TIMELINE}" \
    | tr '|' '\n' | tr -d '"' \
    | grep -oE 'MIG-[0-9]+' | sort -u | tr '\n' ' ')
DISTINCT_MIG_COUNT=$(echo "${DISTINCT_MIG_IDS}" | wc -w | tr -d ' ')

log_info "  peak replicas:            ${PEAK_REPLICAS} (起始 ${INIT_REPLICAS})"
log_info "  peak active MIG count:    ${PEAK_ACTIVE_MIG}"
log_info "  peak MIG↔pod bindings:    ${PEAK_BINDINGS}"
log_info "  distinct MIG IDs seen:    ${DISTINCT_MIG_COUNT} → [${DISTINCT_MIG_IDS}]"

# 判断
if [ "${PEAK_REPLICAS}" -gt "${INIT_REPLICAS}" ] && [ "${PEAK_BINDINGS}" -gt 1 ]; then
    VERDICT="✅ HPA 扩容 + 多 MIG 并行使用,硬件隔离生效"
    PASS=true
elif [ "${PEAK_BINDINGS}" -gt 1 ]; then
    VERDICT="⚠️ 多 MIG 在用但 HPA 没扩(可能 minReplicas 已经 > 1 或负载不够)"
    PASS=true
else
    VERDICT="❌ 只看到 1 个 MIG 在用,无法证明硬件隔离 (HPA 没触发?)"
    PASS=false
fi
log_info "  verdict: ${VERDICT}"
echo

# 汇总 JSON
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
    echo "(timeline 在 ${TIMELINE},每 10 秒一行)"
} >> "${LOG}"

log_info "===== Summary ====="
log_info "  status: $([ ${PASS} = true ] && echo PASSED || echo FAILED)"
log_info "  ${VERDICT}"
log_info "  timeline: ${TIMELINE}"
log_info "  json:     ${JSON}"
