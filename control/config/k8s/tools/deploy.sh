#!/bin/bash
set -e

# Base root for k8s manifests
BASE_DIR="k8s"

echo "Create directory structure under $BASE_DIR ..."

# 1) Base
mkdir -p "$BASE_DIR/base/namespaces"
mkdir -p "$BASE_DIR/base/metallb"
mkdir -p "$BASE_DIR/base/ingress-nginx"
mkdir -p "$BASE_DIR/base/networkpolicy"

# 2) LLM
mkdir -p "$BASE_DIR/llm/web"
mkdir -p "$BASE_DIR/llm/api"
mkdir -p "$BASE_DIR/llm/router"
mkdir -p "$BASE_DIR/llm/workers/vllm"
mkdir -p "$BASE_DIR/llm/workers/trt"
mkdir -p "$BASE_DIR/llm/workers/legacy"

# 3) Monitoring
mkdir -p "$BASE_DIR/monitoring/prometheus"
mkdir -p "$BASE_DIR/monitoring/grafana"
mkdir -p "$BASE_DIR/monitoring/exporters"

echo "Move files into functional directories ..."

# ---------- Base / Namespaces ----------
[ -f "namespace.yaml" ] && mv namespace.yaml "$BASE_DIR/base/namespaces/"

# ---------- Base / MetalLB ----------
[ -f "generate_metallb_ip.sh" ] && mv generate_metallb_ip.sh "$BASE_DIR/base/metallb/"

# ---------- Base / ingress-nginx ----------
[ -f "ingress-nginx-deployment.yaml" ] && mv ingress-nginx-deployment.yaml "$BASE_DIR/base/ingress-nginx/"
[ -f "ingress-nginx-service.yaml" ] && mv ingress-nginx-service.yaml "$BASE_DIR/base/ingress-nginx/"

# ---------- Base / NetworkPolicy ----------
[ -f "llm-networkpolicy.yaml" ] && mv llm-networkpolicy.yaml "$BASE_DIR/base/networkpolicy/"

# ---------- LLM / Web ----------
[ -f "llm-web-deployment.yaml" ] && mv llm-web-deployment.yaml "$BASE_DIR/llm/web/"
[ -f "llm-web-service.yaml" ] && mv llm-web-service.yaml "$BASE_DIR/llm/web/"

# ---------- LLM / API ----------
[ -f "llm-api-deployment.yaml" ] && mv llm-api-deployment.yaml "$BASE_DIR/llm/api/"
[ -f "llm-api-service.yaml" ] && mv llm-api-service.yaml "$BASE_DIR/llm/api/"

# ---------- LLM / Router ----------
[ -f "router-deployment.yaml" ] && mv router-deployment.yaml "$BASE_DIR/llm/router/"
[ -f "router-service.yaml" ] && mv router-service.yaml "$BASE_DIR/llm/router/"

# ---------- LLM / Workers: BERT ----------
[ -f "bert-worker-deployment.yaml" ] && mv bert-worker-deployment.yaml "$BASE_DIR/llm/workers/bert/"
[ -f "bert-worker-service.yaml" ] && mv bert-worker-service.yaml "$BASE_DIR/llm/workers/bert/"

# ---------- LLM / Workers: vLLM ----------
[ -f "vllm-worker-deployment.yaml" ] && mv vllm-worker-deployment.yaml "$BASE_DIR/llm/workers/vllm/"
[ -f "vllm-worker-service.yaml" ] && mv vllm-worker-service.yaml "$BASE_DIR/llm/workers/vllm/"

# ---------- LLM / Workers: TensorRT ----------
[ -f "trt-worker-deployment.yaml" ] && mv trt-worker-deployment.yaml "$BASE_DIR/llm/workers/trt/"
[ -f "trt-worker-service.yaml" ] && mv trt-worker-service.yaml "$BASE_DIR/llm/workers/trt/"

# ---------- LLM / Workers: legacy llm-worker ----------
[ -f "llm-worker-deployment.yaml" ] && mv llm-worker-deployment.yaml "$BASE_DIR/llm/workers/legacy/"
[ -f "llm-worker-service.yaml" ] && mv llm-worker-service.yaml "$BASE_DIR/llm/workers/legacy/"

# ---------- Monitoring / Prometheus ----------
[ -f "prometheus-configmap.yaml" ] && mv prometheus-configmap.yaml "$BASE_DIR/monitoring/prometheus/"
[ -f "prometheus-deployment.yaml" ] && mv prometheus-deployment.yaml "$BASE_DIR/monitoring/prometheus/"

# ---------- Monitoring / Grafana ----------
[ -f "grafana-deployment.yaml" ] && mv grafana-deployment.yaml "$BASE_DIR/monitoring/grafana/"
[ -f "grafana-service.yaml" ] && mv grafana-service.yaml "$BASE_DIR/monitoring/grafana/"

# ---------- Monitoring / Exporters ----------
[ -f "node-exporter.yaml" ] && mv node-exporter.yaml "$BASE_DIR/monitoring/exporters/"
[ -f "dcgm-exporter.yaml" ] && mv dcgm-exporter.yaml "$BASE_DIR/monitoring/exporters/"
[ -f "kube-state-metrics.yaml" ] && mv kube-state-metrics.yaml "$BASE_DIR/monitoring/exporters/"

echo "Done."
echo "New structure is under: $BASE_DIR/"

