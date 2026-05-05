# LLM Deployment Test Suite

End-to-end acceptance tests for your laptop single-node k8s + vLLM (Qwen2.5-0.5B) cluster.

## Run Once

```bash
cd test
./run_all.sh
```

Completes all tests in approximately **8-12 minutes**. Results saved to `test/results/<timestamp>/`.

## What's Included

| # | File | Test Purpose | Key Metrics |
|---|---|---|---|
| 01 | `01_smoke.sh` | Functional correctness | 7 cases (models/single/streaming/multi-turn/max_tokens/error handling) |
| 02 | `02_latency.sh` | Latency baseline (fixed prompt) | P50/P90/P95/P99 at concurrency 1/4/8 |
| 03 | `03_throughput.sh` | Throughput (fixed prompt) | Output tok/s for 4 (short/long prompt × short/long output) combinations |
| 04 | `04_hpa.sh` | HPA scaling | Whether high load triggers replica scaling, how many replicas |
| 05 | `05_stability.sh` | Sustained load | Error rate and pod restarts for 5 minutes (default) |
| **06** | **`06_realistic_load.sh`** | **Realistic load (random prompts)** | **Sample from prompt pool, bypass prefix cache, reflect real production latency/throughput** |

> **Difference between 02/03 vs 06**:
> - 02/03 use **same prompt repeatedly** → vLLM prefix cache 100% hit, prompt processing ~0, data optimistic
> - 06 **randomly sample prompts each time** → cache hit rate ~0%, data close to production
> - Use 02/03 to see "theoretical limit", use 06 to see "actual user experience"

## Run Subset Only

```bash
./run_all.sh smoke latency           # Run only 01 and 02
./run_all.sh hpa                     # Run only 04
```

## Adjust Parameters

```bash
# Point to different endpoint (e.g., port-forward debugging)
TEST_ENDPOINT=http://localhost:8080/api/v1/chat/completions ./run_all.sh

# Run longer stability test (30 minutes)
STABILITY_DURATION=1800 ./run_all.sh stability

# HPA test with longer load duration
HPA_LOAD_DURATION=300 HPA_LOAD_CONCURRENCY=12 ./run_all.sh hpa

# Realistic load test parameters
REALISTIC_DURATION=600 REALISTIC_CONCURRENCY=12 ./run_all.sh realistic
```

Full environment variables documented in each sub-script's header comments.

## Results Location

```
test/results/<timestamp>/
├── SUMMARY.md                    # Read this after completion
├── 00_initial_cluster.txt        # k8s cluster snapshot before test
├── 01_smoke.json                 # Functional test results
├── 01_smoke.log                  # Raw request/response for each case
├── 02_latency.json               # Latency percentiles
├── 02_latency_c{1,4,8}.raw       # Raw latency data (one ms per line)
├── 02_latency_c{1,4,8}.stats.json
├── 03_throughput.json            # Throughput results
├── 03_<scenario>.raw             # Raw (latency, prompt_tokens, completion_tokens)
├── 04_hpa.json                   # HPA trigger summary
├── 04_hpa_timeline.txt           # Pod count + HPA decision every 5 seconds (view with: column -t -s,)
├── 05_stability.json             # Error rate, RPS, restart count
├── 05_stability_snapshots.txt    # Cluster snapshot every 30 seconds
└── 99_final_cluster.txt          # k8s cluster snapshot after test
```

Check `SUMMARY.md` first after completion, then examine specific `.json` / `.log` files if issues.

## Expected Metrics (Laptop RTX 4050 + Qwen2.5-0.5B)

For reference only; actual values depend on your laptop's thermals and time-slicing configuration.

| Metric | Expected |
|---|---|
| Smoke 7 cases | 7/7 pass |
| Single-stream P50 latency (80 token) | 1500-3000ms |
| Concurrency 8 P95 latency | 5000-10000ms |
| Output throughput (single-stream) | 30-50 tok/s |
| Output throughput (concurrency 8) | 80-150 tok/s (continuous batching benefit) |
| HPA peak replicas | 2 (time-slicing limit) |
| 5-minute stability error rate | < 0.5% |
| vllm-worker RESTARTS delta | 0 |

## Dependencies

- `bash` (4.x+)
- `curl`
- `jq`
- `awk`
- `bc`
- `kubectl` (read permissions for namespace `llm` and `monitoring`)

No additional tools required (oha/wrk/ab/k6 etc.), pure shell implementation.

## Troubleshooting

| Symptom | Diagnosis |
|---|---|
| Many 5xx errors | Check `kubectl logs -n llm -l app=vllm-worker --tail=100`, vllm may have crashed |
| Smoke all fail | Wrong endpoint / pods not ready, run `kubectl get pods -A` |
| Very high latency | Check Grafana DCGM dashboard, is GPU contended by other pods? |
| HPA not scaling | `kubectl describe hpa -n llm vllm-worker` check events, usually metrics-server / prometheus-adapter not ready |
| Stability RESTARTS > 0 | `kubectl describe pod -n llm <pod>` check events, possible OOM / liveness probe failure |

## Design Principles

- **Zero external dependencies**: Only what's essential for running k8s on your laptop
- **Self-contained results**: New timestamp directory each run for easy comparison / multi-sampling
- **Fail-safe**: One test failure does not interrupt subsequent tests
- **Idempotent**: Results should be comparable after cluster reset
