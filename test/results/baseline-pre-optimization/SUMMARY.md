# Test Run Summary

- **Started**:   2026-05-05 11:13:18
- **Finished**:  2026-05-05 11:29:05
- **Duration**:  947s
- **Endpoint**:  `http://localhost/api/v1/chat/completions`
- **Model**:     `qwen2.5-0.5b`
- **Results**:   `results/20260505-111318`

## Status

- ✅ `smoke` — ok
- ✅ `latency` — ok
- ✅ `throughput` — ok
- ✅ `hpa` — ok
- ✅ `stability` — ok
- ✅ `realistic` — ok

## 01 — Functional

- pass / total: **7 / 7**

Per-case:

- ✅ `models endpoint`
- ✅ `single completion (non-streaming)`
- ✅ `streaming SSE`
- ✅ `multi-turn conversation`
- ✅ `max_tokens enforcement`
- ✅ `error handling: unknown model returns 4xx`
- ✅ `error handling: empty messages returns 4xx`

## 02 — Latency (ms)

| concurrency | requests | mean | P50 | P90 | P95 | P99 |
|---|---|---|---|---|---|---|
| 1 | 30 | 648.8 | 672 | 722 | 725 | 737 |
| 4 | 30 | 737.1 | 751 | 774 | 789 | 800 |
| 8 | 30 | 808.5 | 825 | 883 | 883 | 884 |

## 03 — Throughput (输出 token/s)

| scenario | requests | concurrency | wall (s) | output tok/s | avg latency (ms) |
|---|---|---|---|---|---|
| short_short | 16 | 8 | 1.19 | 366.0 | 420 |
| short_long | 16 | 8 | 1.16 | 437.2 | 432 |
| long_short | 16 | 8 | 1.24 | 644.1 | 606 |
| long_long | 16 | 8 | 5.82 | 824.2 | 2897 |

## 04 — HPA Autoscaling

- HPA range: `[1 .. 2]`
- replicas: initial=1, **peak=2**, final=2
- ✅ HPA 触发了扩容

时间线见 `04_hpa_timeline.txt`(每 5 秒一行)。

## 05 — Stability

- duration: 300s
- requests: OK=842  ERR=0  (rate=0.0000%)
- RPS: 2.81
- vllm-worker RESTARTS Δ: 0
- ✅ stability **PASSED**

## 06 — Realistic Load (随机 prompt,无 prefix-cache 加速)

- duration: s, concurrency: , prompt pool: 
- OK=  ERR=  (rate=%, RPS=)

**整体延迟 (ms):**
| count | min | max | mean | P50 | P90 | P95 | P99 |
|---|---|---|---|---|---|---|---|
|  |  |  |  |  |  |  |  |

**按 prompt 长度分组的延迟 P50/P95 (ms):**
| bucket | count | P50 | P95 |
|---|---|---|---|
| short |  |  |  |
| medium |  |  |  |
| long |  |  |  |

**Token 吞吐 (基于 wall time):**
- output tok/s: ****
- total tok/s (含 prompt): 

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
- `06_prompt_pool.txt`
- `06_realistic_errors.log`
- `06_realistic.json`
- `06_realistic.raw`
- `99_final_cluster.txt`
- `SUMMARY.md`
