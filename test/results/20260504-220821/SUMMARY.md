# Test Run Summary

- **Started**:   2026-05-04 22:08:21
- **Finished**:  2026-05-04 22:18:07
- **Duration**:  586s
- **Endpoint**:  `http://localhost/api/v1/chat/completions`
- **Model**:     `qwen2.5-0.5b`
- **Results**:   `results/20260504-220821`

## Status

- ❌ `smoke` — failed
- ✅ `latency` — ok
- ✅ `throughput` — ok
- ✅ `hpa` — ok
- ✅ `stability` — ok

## 01 — Functional

- pass / total: **5 / 7**
- ❌ failures: 2

Per-case:

- ✅ `models endpoint`
- ✅ `single completion (non-streaming)`
- ✅ `streaming SSE`
- ✅ `multi-turn conversation`
- ✅ `max_tokens enforcement`
- ❌ `error handling: unknown model returns 4xx`
- ❌ `error handling: empty messages returns 4xx`

## 02 — Latency (ms)

| concurrency | requests | mean | P50 | P90 | P95 | P99 |
|---|---|---|---|---|---|---|
| 1 | N/A | N/A | N/A | N/A | N/A | N/A |
| 4 | N/A | N/A | N/A | N/A | N/A | N/A |
| 8 | N/A | N/A | N/A | N/A | N/A | N/A |

## 03 — Throughput (输出 token/s)

| scenario | requests | concurrency | wall (s) | output tok/s | avg latency (ms) |
|---|---|---|---|---|---|
| short_short | N/A | N/A | N/A | N/A | N/A |
| short_long | N/A | N/A | N/A | N/A | N/A |
| long_short | N/A | N/A | N/A | N/A | N/A |
| long_long | N/A | N/A | N/A | N/A | N/A |

## 04 — HPA Autoscaling

- HPA range: `[1 .. 2]`
- replicas: initial=1, **peak=1**, final=1
- ⚠️  HPA 没扩容(load 不足 / metrics 不就绪 / 阈值过高)

时间线见 `04_hpa_timeline.txt`(每 5 秒一行)。

## 05 — Stability

- duration: 300s
- requests: OK=1130  ERR=0  (rate=0.0000%)
- RPS: 3.77
- vllm-worker RESTARTS Δ: 0
- ✅ stability **PASSED**

---

## 文件清单

- `00_initial_cluster.txt`
- `01_smoke.json`
- `01_smoke.log`
- `02_latency_c1.raw`
- `02_latency_c1.stats.json`
- `02_latency_c4.raw`
- `02_latency_c4.stats.json`
- `02_latency_c8.raw`
- `02_latency_c8.stats.json`
- `02_latency.json`
- `02_latency.log`
- `03_long_long.raw`
- `03_long_short.raw`
- `03_short_long.raw`
- `03_short_short.raw`
- `03_throughput.json`
- `03_throughput.log`
- `04_hpa.json`
- `04_hpa.log`
- `04_hpa_timeline.txt`
- `05_err_count`
- `05_ok_count`
- `05_stability.json`
- `05_stability_snapshots.txt`
- `99_final_cluster.txt`
- `SUMMARY.md`
