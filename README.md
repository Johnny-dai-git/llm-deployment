# LLM Deployment

Self-hosted, Kubernetes-based LLM inference platform. OpenAI-compatible API on top of vLLM, fully observable, with GitOps continuous deployment.

```
┌─────────────────────────────────────────────────────────────────┐
│                    External Client (Browser / CLI)              │
└──────────────────────────────┬──────────────────────────────────┘
                               │ HTTP
                               ▼
                       ingress-nginx (host:80)
                               │
                ┌──────────────┴──────────────┐
                │ /api                        │ /web
                ▼                             ▼
    ┌──────────────────┐            ┌──────────────────┐
    │  llm-api         │ ◄─ HPA ◄─  │  llm-web         │
    │  (FastAPI)       │  CPU>60%   │  (nginx + SSE)   │
    │  - auth          │  1↔3 reps  └──────────────────┘
    │  - SSE streaming │
    └────────┬─────────┘
             │ HTTP (OpenAI compatible)
             ▼
    ┌──────────────────┐ ◄─ HPA ◄─  vllm:num_requests_waiting > 5
    │  vllm-worker     │  custom    1↔2 reps (GPU slot-bound)
    │  (vLLM + GPU)    │  metric
    │  - PagedAttn     │
    │  - cont. batching│
    └──────────────────┘

   Scaled by:    HPA + metrics-server (CPU) + prometheus-adapter (custom)
   Observed by:  Prometheus + Grafana + DCGM exporter
   Deployed by:  ArgoCD + ArgoCD Image Updater (GitOps)
   Built by:     GitHub Actions self-hosted runner → GHCR
```

## What's Inside

- **OpenAI-compatible API** with SSE streaming for chat completions
- **GPU inference** via vLLM (currently `Qwen2.5-0.5B-Instruct`)
- **GitOps deployment** via ArgoCD watching this repo
- **Auto image updates** via ArgoCD Image Updater watching GHCR
- **Full observability**: Prometheus + Grafana + DCGM (GPU metrics) + ServiceMonitors for the business services
- **Autoscaling**: HPA on `llm-api` (CPU) and `vllm-worker` (vLLM queue depth via prometheus-adapter)
- **GPU time-slicing** so a single laptop GPU presents 2 schedulable slots, allowing rolling updates without downtime
- **Self-hosted CI**: GitHub Actions self-hosted runner builds and pushes images on every commit to `main` / `telemetry`

## Quick Start (laptop)

Three commands. The whole thing comes up in 5–15 minutes.

```bash
# 1. Clone and enter the repo
git clone https://github.com/Johnny-dai-git/llm-deployment.git
cd llm-deployment
git checkout telemetry            # current dev mainline

# 2. Download the model weights once (~1 GB, idempotent)
bash script/laptop/download-model.sh

# 3. Bootstrap the cluster + everything on top
sudo bash script/laptop/launch.sh
```

Once the script finishes you'll see a list of access URLs:

| URL | What |
|---|---|
| `http://localhost/web` | Chat UI with markdown + streaming |
| `http://localhost/api/v1/chat/completions` | OpenAI-compatible endpoint |
| `http://localhost/grafana` | Dashboards (anonymous Admin) |
| `http://localhost/prometheus` | Metrics querying |
| `http://localhost/argocd` | GitOps UI |
| `http://localhost/` | Landing page with links |

## Prerequisites

- **OS**: Ubuntu 22.04+ (the `all_install.sh` script targets the apt ecosystem)
- **GPU** (recommended): NVIDIA GPU with 6 GB+ VRAM. The repo runs in CPU-only mode but `vllm-worker` will Pend without a GPU.
- **Disk**: ~30 GB free for K8s state + model weights + container images
- **Docker** + **kubeadm** + **helm**: installed automatically by `all_install.sh`

## Project Structure

```
llm-deployment/
├── app/                              # Source for our own services
│   ├── gateway/                      # FastAPI: auth + SSE + forward (= "llm-api")
│   ├── worker/vllm/                  # vLLM worker Dockerfile
│   └── web/                          # nginx + chat UI (HTML + marked.js)
│
├── tools/                            # Kubernetes manifests (GitOps source of truth)
│   ├── llm/                          # Business namespace (kustomized)
│   │   ├── api/                      # llm-api Deployment + Service + ServiceMonitor + HPA
│   │   ├── workers/vllm/             # vllm-worker Deployment + Service + SM + HPA
│   │   ├── web/                      # web Deployment + Service + nginx ConfigMap
│   │   ├── ingress/                  # /api and /web routing
│   │   ├── landing/                  # /landing page
│   │   └── kustomization.yaml
│   ├── argocd-image-updater/         # SA, RBAC, Deployment, Application
│   ├── helm/                         # Helm values for ArgoCD, monitoring stack
│   │   ├── argocd/values.yaml
│   │   └── monitoring/
│   │       ├── kps-values.yaml       # kube-prometheus-stack values
│   │       ├── dcgm/values.yaml      # NVIDIA DCGM exporter values
│   │       └── prometheus-adapter-values.yaml  # custom metrics for HPA
│   └── system/                       # Cluster-level: NVIDIA device plugin, RuntimeClass
│
├── script/                           # Bootstrap scripts split per environment
│   ├── laptop/                       # Single-node laptop bootstrap
│   │   ├── all_install.sh            # Docker + kubeadm + helm
│   │   ├── system.sh                 # kubeadm reset + init + Calico CNI
│   │   ├── launch.sh                 # one-shot orchestrator (calls the above)
│   │   ├── build-and-push.sh         # local image build (when CI is too slow)
│   │   └── download-model.sh         # fetch Qwen2.5-0.5B from HuggingFace
│   └── lambda/                       # (legacy folder; cloud work now on GCP_BRANCH)
│
├── description/                      # ASCII architecture diagrams (zh + en)
└── .github/workflows/local-build.yml # CI: build + push images on push to main/telemetry
```

## CI/CD Flow

```
You push code to telemetry
        │
        ▼
GitHub Actions detects push, dispatches workflow
        │
        ▼
Self-hosted runner on this laptop picks up the job
        │
        ├─ Docker build changed images (paths-filter)
        │  - app/gateway/**       → rebuild gateway
        │  - app/worker/vllm/**   → rebuild vllm-worker
        │  - app/web/**           → rebuild web
        │
        └─ docker push ghcr.io/johnny-dai-git/llm-deployment/<svc>:v-<timestamp>
                │
                ▼
        ArgoCD Image Updater (running in cluster) scans GHCR every 2 min
                │
                ▼
        Detects new tag matching regex ^v-[0-9]{8}-[0-9]{6}$
                │
                ▼
        Patches the ArgoCD Application's image-list
                │
                ▼
        ArgoCD performs a rolling update of the Deployment
                │
                ▼
        New version live, browser refresh shows it
```

For local debugging without going through CI:

```bash
bash script/laptop/build-and-push.sh
```

This builds and pushes all three service images directly to GHCR using the same timestamp tag scheme.

## Components

### Application Layer (we own)

| Service | Purpose | Image |
|---|---|---|
| `llm-api` (gateway) | OpenAI-compatible HTTP frontend; auth + request validation + forward to vllm-worker; SSE streaming | `ghcr.io/.../gateway` |
| `vllm-worker` | GPU inference; vLLM with PagedAttention and continuous batching | `ghcr.io/.../vllm-worker` |
| `llm-web` | Static chat UI (nginx + HTML + marked.js for markdown) | `ghcr.io/.../web` |

### Platform Layer (third-party, Helm-installed)

| Component | Purpose |
|---|---|
| `ingress-nginx` | L7 ingress; binds host network on port 80 |
| `argocd` | GitOps controller |
| `argocd-image-updater` | Watches GHCR for new tags |
| `kube-prometheus-stack` | Prometheus + Grafana + Alertmanager + node-exporter + kube-state-metrics |
| `dcgm-exporter` | NVIDIA GPU metrics |
| `metrics-server` | Resource metrics for HPA |
| `prometheus-adapter` | Translates Prometheus series into K8s Custom Metrics API for HPA |

### Probes Strategy

Every Pod has the full `startupProbe + readinessProbe + livenessProbe` triplet:

- `vllm-worker`: startup/readiness on `/v1/models` (returns 200 only after model is loaded), liveness on `/health` (process-level, gentle restarts)
- `llm-api`, `llm-web`, `landing-nginx`: same endpoint for all three probes (no meaningful intermediate state), differentiated by timing parameters

### Monitoring Layer

Business metrics actually flow into Prometheus via `ServiceMonitor` resources:

- `tools/llm/api/api-servicemonitor.yaml` — exposes `llm_api_requests_total`, `llm_api_request_latency_seconds`
- `tools/llm/workers/vllm/vllm-servicemonitor.yaml` — exposes vLLM's rich metrics (`vllm:e2e_request_latency_seconds`, `vllm:gpu_cache_usage_perc`, `vllm:num_requests_running`, `vllm:num_requests_waiting`, etc.)

The `kube-prometheus-stack` selectors are wide open (`{}`) so any ServiceMonitor in any namespace gets scraped — appropriate for a single-team setup.

### Autoscaling (HPA)

Both compute services scale horizontally on real load signals — not on a static replica count. The two HPAs use **different metric backends** because the two services are bottlenecked by different things:

```
llm-api HPA  (CPU-bound)               vllm-worker HPA  (GPU-bound)
  metric source: metrics-server          metric source: prometheus-adapter
  signal: cpu utilization > 60%          signal: vllm:num_requests_waiting > 5/pod
  range:  1 ↔ 3 replicas                 range:  1 ↔ 2 replicas
  scaleUp: +100% / 60s                   scaleUp: +1 pod / 120s
  scaleDown: -50% / 120s                 scaleDown: -1 pod / 300s
```

**Why different metrics?**

CPU utilization is the right knob for `llm-api` — its work is JSON serialization + httpx forwarding, which loads CPU proportionally to traffic. For `vllm-worker`, CPU is meaningless (the bottleneck is the GPU), so we scale on vLLM's own queue depth: when `num_requests_waiting` per pod stays high, we add another worker.

**Why is `vllm-worker` capped at 2?**

The `nvidia-device-plugin` is configured for time-slicing into 2 slots on a single GPU (`tools/system/nvidia-device-plugin.yaml`). Asking K8s for a third `nvidia.com/gpu: 1` would Pend forever. On a multi-GPU node (e.g. GCP A100/H100/L4), bump the HPA `maxReplicas` and switch the device plugin to MIG.

**Components required for HPA to work** (all installed by `launch.sh`):

| Component | Provides | Used by |
|---|---|---|
| `metrics-server` | CPU/memory resource metrics | `llm-api` HPA |
| `prometheus-adapter` | `vllm:*` Prometheus series exposed as Custom Metrics API | `vllm-worker` HPA |
| `kube-prometheus-stack` | The Prometheus that prometheus-adapter reads from | upstream of prometheus-adapter |
| ServiceMonitors in `tools/llm/` | Make sure `vllm:*` series actually flow into Prometheus | upstream of prometheus-adapter |

**Conservative scaleDown timings** (long stabilization window) are intentional: tearing down a `vllm-worker` Pod loses its KV cache and forces the next request to JIT-compile CUDA kernels again. We trade a few extra minutes of an idle pod for a smoother experience.

## Common Tasks

### Iterate on application code

```bash
# Edit app/gateway/gateway.py or wherever
git add -A
git commit -m "fix: ..."
git push origin telemetry
# → CI builds and pushes new image
# → Image Updater detects new tag (~2 min)
# → ArgoCD rolling-updates the Deployment (~1 min)
# → Refresh browser to see your change live
```

### Inspect the cluster

```bash
kubectl get pods -A                                           # everything
kubectl get pods -n llm                                       # business namespace
kubectl logs -n llm -l app=llm-api -f                         # live logs
kubectl describe pod -n llm <pod>                             # one pod's full state
kubectl get hpa -n llm                                        # autoscaler status
kubectl get servicemonitor -n llm                             # what Prometheus is scraping
```

### Verify metrics flow

```bash
# After launch, in Prometheus UI:
http://localhost/prometheus/targets

# Should see UP:
#   serviceMonitor/llm/llm-api/0
#   serviceMonitor/llm/vllm-worker/0
#   serviceMonitor/monitoring/dcgm-exporter/0   (only if GPU)

# Useful PromQL:
llm_api_requests_total
vllm:num_requests_running
DCGM_FI_DEV_GPU_UTIL
```

### Verify HPA is wired up

```bash
# 1. The two HPAs should be present:
kubectl get hpa -n llm
# NAME          REFERENCE                TARGETS         MINPODS   MAXPODS   REPLICAS
# llm-api       Deployment/llm-api       12%/60%, ...    1         3         1
# vllm-worker   Deployment/vllm-worker   0/5             1         2         1

# 2. metrics-server is supplying CPU/memory metrics:
kubectl top pod -n llm
# NAME                CPU(cores)   MEMORY(bytes)
# llm-api-xxx         5m           80Mi
# vllm-worker-xxx     ...

# 3. prometheus-adapter is exposing the custom metric used by vllm-worker HPA:
kubectl get --raw \
  "/apis/custom.metrics.k8s.io/v1beta1/namespaces/llm/pods/*/vllm_num_requests_waiting" \
  | jq

# If the URL above returns "no metrics returned" before any traffic, that's
# expected — vLLM only emits the series after the first request.
```

### Trigger a real load test (and watch HPA react)

```bash
# Install hey
sudo apt install hey

# Hit the gateway hard
hey -n 1000 -c 50 -m POST \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5-0.5b","messages":[{"role":"user","content":"hi"}],"max_tokens":50}' \
  http://localhost/api/v1/chat/completions

# In another terminal, watch llm-api HPA scale up and replicas go from 1 → 2 → 3
watch -n 2 'kubectl get hpa -n llm; echo; kubectl get pods -n llm'

# After 5+ minutes idle, scaleDown kicks in and replicas drop back to 1
```

## Performance Baseline

End-to-end benchmark on the laptop reference setup: **single-node K8s, NVIDIA RTX 4050 Laptop (6 GB VRAM, ~192 GB/s mem bandwidth), Qwen2.5-0.5B fp16, vLLM 0.11**. Full raw results live in [`test/results/baseline-pre-optimization/`](test/results/baseline-pre-optimization). Reproduce with:

```bash
cd test
./run_all.sh                 # ~17 min, all 6 stages, generates SUMMARY.md
```

### 01 — Functional (7 / 7 passed)

`/v1/models` · single completion · SSE streaming · multi-turn · `max_tokens` enforcement · unknown-model 4xx · empty-messages 4xx — all green.

### 02 — Latency (fixed prompt, prefix-cache hit; 30 req per level)

| Concurrency | Mean | P50 | P90 | P95 | P99 |
|---|---|---|---|---|---|
| 1 | 649 ms | 672 ms | 722 ms | 725 ms | 737 ms |
| 4 | 737 ms | 751 ms | 774 ms | 789 ms | 800 ms |
| 8 | 809 ms | 825 ms | 883 ms | 883 ms | 884 ms |

Concurrency 8 P50 only **23% higher** than single-stream — vLLM continuous batching works as advertised.

### 03 — Throughput (fixed prompt, prefix-cache hit; 16 req per scenario, concurrency 8)

| Scenario | Output tok/s | Wall | Avg latency |
|---|---|---|---|
| Short prompt + short output | 366.0 | 1.19 s | 420 ms |
| Short prompt + long output  | 437.2 | 1.16 s | 432 ms |
| Long prompt + short output  | 644.1 | 1.24 s | 606 ms |
| **Long prompt + long output** | **824.2** | 5.82 s | 2.9 s |

Peak **~824 tok/s** under 8-way batched load — about **70-80% of the theoretical memory-bandwidth-bound ceiling** for fp16 Qwen2.5-0.5B on this GPU.

### 04 — HPA Autoscaling (240 s sustained load, concurrency 20)

- HPA range: `[1, 2]` (capped by GPU time-slicing slots)
- Replicas: initial 1 → **peak 2** ✅
- Trigger: `vllm:num_requests_waiting` averaged > 5 over a 60 s stabilization window
- Path: vLLM `/metrics` → Prometheus → prometheus-adapter → HPA v2

### 05 — Sustained Load Stability (300 s, concurrency 4)

| Metric | Value |
|---|---|
| Total requests | 842 |
| Errors | **0** (0.00%) |
| RPS | 2.81 |
| `vllm-worker` pod restarts | **0** |

### 06 — Realistic Load (300 s, concurrency 8, **60 random prompts** to defeat prefix cache)

| Metric | Value |
|---|---|
| Total OK requests | 680 |
| Errors | 3 (0.44%) |
| **Output tok/s (sustained)** | **433.8** |
| Total tok/s (incl. prompt) | 554.3 |
| RPS | 2.27 |
| **P50 latency** | **2 484 ms** |
| P95 latency | 5 881 ms |
| P99 latency | 6 379 ms |

### 02/03 vs 06 — Why the Two Numbers Both Matter

| | 02 / 03 (fixed prompt, cache 100% hit) | 06 (random prompts, cache miss) | Ratio |
|---|---|---|---|
| Single-stream P50 latency | 672 ms | 2 484 ms | **3.7× slower without cache** |
| Output throughput | ~824 tok/s **peak** | ~434 tok/s **sustained** | **0.53× under real traffic** |

Stages 02 and 03 reuse the same prompt for every request, so vLLM's automatic prefix caching hits ~100% and prompt-processing time collapses to near zero — these numbers represent the **theoretical ceiling**. Stage 06 samples randomly from a 60-prompt pool covering Chinese & English, programming, math, and creative writing, so cache hit rate ≈ 0% — these numbers represent **real production throughput and latency**.

**Capacity planning should use the 06 numbers (~434 tok/s sustained, P95 5.9 s), not the 824 tok/s peak.**

## Cloud Deployment

A separate `GCP_BRANCH` tracks the work for moving this stack onto GCP (GKE + GPU node pool, MIG instead of time-slicing, Artifact Registry instead of GHCR, GCS-mounted models). The `laptop` setup here is the reference deployment.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `vllm-worker` Pod stuck in `CrashLoopBackOff` | Model files not present at the hostPath | `bash script/laptop/download-model.sh` |
| `vllm-worker` Pod `Pending` | No node satisfies `gpu-node=true` + `nvidia.com/gpu: 1` | Confirm `lspci | grep -i nvidia`, check `nvidia-device-plugin` Pod is `Running` in `kube-system` |
| `llm-api` returns 502 | `vllm-worker` is down or model not loaded | `kubectl logs -n llm -l app=vllm-worker` |
| Streaming response arrives all at once instead of token-by-token | ingress-nginx is buffering | Confirm `unified-ingress.yaml` has `nginx.ingress.kubernetes.io/proxy-buffering: "off"` |
| GHCR push fails with `unauthenticated` during build-and-push.sh | Token revoked or wrong scope | Regenerate GitHub PAT with `write:packages` scope, then `docker logout ghcr.io && docker login ghcr.io -u <user> --password-stdin <<< $TOKEN` |
| ArgoCD shows `OutOfSync` | Probably normal mid-deploy. If persistent, check the Application's status in `http://localhost/argocd` |
| HPA shows `<unknown>/<target>` for `vllm-worker` | `prometheus-adapter` not yet healthy or `vllm:num_requests_waiting` series doesn't exist (no traffic yet) | `kubectl get pods -n monitoring | grep prometheus-adapter`; send some traffic so the metric exists |

## License

This is a personal learning project; no formal license. Use at your own risk.
