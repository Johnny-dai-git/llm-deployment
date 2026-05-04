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
    │  llm-api         │            │  llm-web         │
    │  (FastAPI)       │            │  (nginx + SSE)   │
    │  - auth          │            └──────────────────┘
    │  - SSE streaming │
    └────────┬─────────┘
             │ HTTP (OpenAI compatible)
             ▼
    ┌──────────────────┐
    │  vllm-worker     │
    │  (vLLM + GPU)    │
    │  - PagedAttn     │
    │  - cont. batching│
    └──────────────────┘

   Observed by: Prometheus + Grafana + DCGM exporter
   Deployed by: ArgoCD + ArgoCD Image Updater (GitOps)
   Built by:    GitHub Actions self-hosted runner → GHCR
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
│   └── lambda/                       # Cloud-side scripts (still developing)
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

### Autoscaling

- `llm-api` HPA: 1–3 replicas, scales on CPU > 60% (memory > 75% as safety net)
- `vllm-worker` HPA: 1–2 replicas (limited by GPU time-slicing slots), scales on `vllm_num_requests_waiting > 5` per pod

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

### Trigger a real load test

```bash
# Install hey
sudo apt install hey

# Hit the gateway
hey -n 1000 -c 50 -m POST \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5-0.5b","messages":[{"role":"user","content":"hi"}],"max_tokens":50}' \
  http://localhost/api/v1/chat/completions

# Watch HPA react
watch -n 2 'kubectl get hpa -n llm'
```

## Lambda Migration Notes

This setup runs on a single-node laptop. To move to Lambda Labs (or any multi-node cluster):

- Build out `script/lambda/launch.sh` based on `script/laptop/launch.sh`
- Replace GPU time-slicing with MIG on H100/A100 (`tools/system/nvidia-device-plugin.yaml` → use `migStrategy: single|mixed` instead of the time-slicing config)
- Bump `vllm-hpa.yaml` `maxReplicas` from 2 to whatever your GPU count supports
- Update `vllm-worker-deployment.yaml` `--gpu-memory-utilization` back to 0.8+ once each Pod has its own real GPU
- Update `vllm-worker-deployment.yaml` `hostPath` from `/home/johnny/Desktop/projects/llm-server/models` to wherever Lambda mounts model weights
- Add `nvidia.com/gpu:NoSchedule` taint to GPU nodes and matching toleration in vllm-worker / dcgm to prevent unrelated Pods from scheduling onto GPU nodes
- Stop hardcoding the node name `system` in `script/.../system.sh` (use `$(hostname -s)` or `kubectl get nodes -o jsonpath=...`)
- Add a real `imagePullSecret` if GHCR packages stay private (or change them to public)
- Switch `argocd-image-updater/llm-application.yaml` `targetRevision` back to `main` once telemetry is promoted

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
