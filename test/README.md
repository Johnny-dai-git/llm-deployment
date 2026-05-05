# LLM 部署测试套件

针对你笔记本上单节点 k8s + vLLM (Qwen2.5-0.5B) 集群的端到端验收测试。

## 跑一次

```bash
cd test
./run_all.sh
```

默认大约 **8-12 分钟**跑完所有测试。结果落到 `test/results/<timestamp>/`。

## 包含什么

| # | 文件 | 测什么 | 关键指标 |
|---|---|---|---|
| 01 | `01_smoke.sh` | 功能正确性 | 7 个 case (models/single/streaming/multi-turn/max_tokens/error handling) |
| 02 | `02_latency.sh` | 延迟基线 (固定 prompt) | 并发 1/4/8 下的 P50/P90/P95/P99 |
| 03 | `03_throughput.sh` | 吞吐量 (固定 prompt) | 4 种 (短/长 prompt × 短/长 output) 组合的 output tok/s |
| 04 | `04_hpa.sh` | HPA 扩容 | 高负载下能否触发副本扩容,扩到几个 |
| 05 | `05_stability.sh` | 持续负载 | 5 分钟 (默认) 的错误率、pod 重启情况 |
| **06** | **`06_realistic_load.sh`** | **真实负载 (随机 prompt)** | **从 prompt pool 抽,绕过 prefix cache,反映生产真实延迟/吞吐** |

> **02/03 vs 06 的区别**:
> - 02/03 **固定 prompt** 反复打 → vLLM prefix cache 100% 命中,prompt 处理时间近 0,数据偏乐观
> - 06 **每次随机抽 prompt** → cache 命中率 ~0%,数据贴近生产
> - 02/03 用来看"理论上限",06 用来看"用户实际体验"

## 只跑部分

```bash
./run_all.sh smoke latency           # 只跑 01 和 02
./run_all.sh hpa                     # 只跑 04
```

## 调整参数

```bash
# 指向别的端点(比如 port-forward 调试)
TEST_ENDPOINT=http://localhost:8080/api/v1/chat/completions ./run_all.sh

# 跑长一点的稳定性测试(30 分钟)
STABILITY_DURATION=1800 ./run_all.sh stability

# HPA 测试加大负载持续时间
HPA_LOAD_DURATION=300 HPA_LOAD_CONCURRENCY=12 ./run_all.sh hpa

# 真实负载测试参数
REALISTIC_DURATION=600 REALISTIC_CONCURRENCY=12 ./run_all.sh realistic
```

完整环境变量见各 sub-script 顶部注释。

## 结果在哪

```
test/results/<timestamp>/
├── SUMMARY.md                    # 跑完之后看这个就够
├── 00_initial_cluster.txt        # 跑前的 k8s 集群快照
├── 01_smoke.json                 # 功能测试结果
├── 01_smoke.log                  # 每个 case 的请求/响应原文
├── 02_latency.json               # 延迟分位数
├── 02_latency_c{1,4,8}.raw       # 原始 latency 数据 (每行一个 ms)
├── 02_latency_c{1,4,8}.stats.json
├── 03_throughput.json            # 吞吐量结果
├── 03_<scenario>.raw             # 原始 (latency, prompt_tokens, completion_tokens)
├── 04_hpa.json                   # HPA 触发情况汇总
├── 04_hpa_timeline.txt           # 每 5 秒一行的 pod count + HPA 决策(可用 column -t -s, 看)
├── 05_stability.json             # 错误率、RPS、重启次数
├── 05_stability_snapshots.txt    # 每 30 秒一次的集群快照
└── 99_final_cluster.txt          # 跑后的 k8s 集群快照
```

跑完先看 `SUMMARY.md`,有问题再看具体的 `.json` / `.log`。

## 期望的指标范围 (笔记本 RTX 4050 Laptop + Qwen2.5-0.5B)

仅供对照,实际值跟你笔记本散热、time-slicing 配置都有关。

| 指标 | 期望 |
|---|---|
| smoke 7 个 case | 7/7 pass |
| 单流 P50 延迟(80 token) | 1500-3000ms |
| 并发 8 P95 延迟 | 5000-10000ms |
| output throughput (单流) | 30-50 tok/s |
| output throughput (并发 8) | 80-150 tok/s (continuous batching 增益) |
| HPA peak replicas | 2 (time-slicing 上限) |
| 5 分钟稳定性错误率 | < 0.5% |
| vllm-worker RESTARTS Δ | 0 |

## 依赖

- `bash` (4.x+)
- `curl`
- `jq`
- `awk`
- `bc`
- `kubectl` (有权限读 namespace `llm` 和 `monitoring`)

无需 oha/wrk/ab/k6 等额外工具,纯 shell 实现。

## 触发问题怎么办

| 症状 | 排查 |
|---|---|
| 大量 5xx | 看 `kubectl logs -n llm -l app=vllm-worker --tail=100`,可能 vllm 崩了 |
| smoke 全 fail | 端点不对 / pods 不 ready,先 `kubectl get pods -A` |
| 延迟特别长 | 看 Grafana DCGM dashboard,GPU 是否被别的 pod 抢占 |
| HPA 没扩容 | `kubectl describe hpa -n llm vllm-worker` 看 events,通常是 metrics-server / prometheus-adapter 没就绪 |
| 稳定性 RESTARTS > 0 | `kubectl describe pod -n llm <pod>` 看 events,可能是 OOM / liveness probe 失败 |

## 设计原则

- **零外部依赖**:除了你笔记本上跑 k8s 必备的那几个,没有再装额外工具
- **结果自包含**:每次跑都开一个新 timestamp 目录,方便前后对比 / 多次取样
- **失败不中断**:任何一个测试 fail,后面继续跑
- **幂等**:reset 集群之后再跑结果应该可比
