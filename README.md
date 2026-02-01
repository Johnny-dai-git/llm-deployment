# LLM Deployment Platform

This repo is a self-hosted, Kubernetes-based LLM serving stack. It turns a trained model into a running API + web app with routing, monitoring, and GitOps automation. It is intended for teams who want to serve models on their own GPU infrastructure (cloud or on‑prem) instead of relying on a managed hosting provider.

## What this repo provides

- OpenAI-compatible API gateway (`app/gateway`)
- Router that forwards requests to worker backends (`app/router`)
- GPU workers (vLLM and TensorRT-LLM) (`app/worker`, `tools/llm/workers`)
- Static web chat UI (`app/web`)
- Kubernetes manifests + Kustomize for the full stack (`tools/llm`)
- GitOps via ArgoCD + Image Updater (`tools/argocd-image-updater`, `tools/helm/argocd`)
- Monitoring stack (Prometheus/Grafana, DCGM GPU metrics) (`tools/helm/monitoring`)

## Quick start (launch.sh)

This is a single-node bootstrap flow. It installs dependencies, initializes Kubernetes, and deploys ingress, ArgoCD, monitoring, and the LLM services.

### Prerequisites

- Ubuntu/Debian-based host with `sudo`
- Internet access (for apt/helm/image pulls)
- NVIDIA GPU + driver for vLLM/TensorRT workers
- Free disk at the storage device mount used by the script

### Important warning

`script/launch.sh` calls `script/system.sh`, which **resets Kubernetes state and modifies system config** (disables swap, rewrites `/etc`, runs `kubeadm reset`, etc.). Run this on a fresh machine or a node you are OK to wipe.

### Steps

1. Clone this repo onto the target node.
2. (Optional) edit `script/launch.sh`:
   - `STORAGE_DEVICE` (default `/dev/sda4`) to match your disk
   - `GITHUB_USERNAME`, `GITHUB_REPO`, `GITHUB_BRANCH` if you forked
3. Run:

```bash
sudo bash script/launch.sh
```

4. Verify:

```bash
kubectl get pods -A
kubectl get nodes -o wide
```

### Access

Ingress is configured without a hostname, so you can access via the node IP:

- Landing page: `http://<node-ip>/`
- Web UI: `http://<node-ip>/web`
- API gateway: `http://<node-ip>/api/v1/chat/completions`

## Deploy your trained model (vLLM path)

1. Copy your model files onto the node.
   - Default host path: `/home/ubuntu/k8s/model/<model-name>`
2. Update the vLLM worker args in `tools/llm/workers/vllm/vllm-worker-deployment.yaml`:
   - `--model=/model/<model-name>`
   - `--served-model-name=<model-name>`
3. Apply manifests:

```bash
kubectl apply -k tools/llm
```

(If ArgoCD is running, you can also let it sync automatically.)

## Build and push images (optional)

Use `script/build-and-push.sh` to build all images and push to GHCR. ArgoCD Image Updater watches version tags (`v-YYYYMMDD-HHMMSS`) and updates the deployments in Git automatically.

```bash
bash script/build-and-push.sh
```
