# Monitoring Helm Charts

This directory contains configuration files for managing monitoring components with Helm.

## File descriptions

- `kps-values.yaml`: Helm values configuration for kube-prometheus-stack
- `dcgm/values.yaml`: Helm values configuration for dcgm-exporter

## Migration steps

### Step 0: Disable existing YAML Application

In ArgoCD UI:
1. Find the `llm-platform-monitoring` Application
2. Click "Delete" (do not check "Cascade")
3. This will stop managing old resources but not delete them

### Step 1: Apply new Helm Applications

```bash
# Apply kube-prometheus-stack
kubectl apply -f tools/config/argocd-apps/monitoring-helm-application.yaml

# Apply dcgm-exporter
kubectl apply -f tools/config/argocd-apps/dcgm-helm-application.yaml
```

### Step 2: Sync in ArgoCD UI

1. Open ArgoCD UI
2. Find newly created Applications:
   - `llm-platform-monitoring-helm`
   - `dcgm-exporter-helm`
3. Click "Sync" button

### Step 3: Verify

```bash
# Check Pod status
kubectl get pods -n monitoring

# Check Grafana
kubectl get ingress -n monitoring

# Access Grafana
# http://<hostNetwork-IP>/grafana
# username: admin
# password: admin
```

## Local testing (optional)

If you want to test locally before applying ArgoCD:

```bash
# Add Helm repositories
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add nvidia https://nvidia.github.io/dcgm-exporter/helm-charts
helm repo update

# Install kube-prometheus-stack
helm install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f tools/helm/monitoring/kps-values.yaml

# Install dcgm-exporter
helm install dcgm nvidia/dcgm-exporter \
  -n monitoring \
  -f tools/helm/monitoring/dcgm/values.yaml
```

## Clean up old resources (optional)

After Helm chart deployment succeeds and is verified, you can manually clean up old resources:

```bash
# Only delete old Deployment/Service/Ingress, retain PVC
kubectl delete deploy grafana prometheus -n monitoring --ignore-not-found
kubectl delete svc grafana prometheus -n monitoring --ignore-not-found
kubectl delete ingress grafana-ingress -n monitoring --ignore-not-found
```

## Configuration notes

### Grafana
- Subpath: `/grafana`
- Ingress: Use nginx, retain `/grafana` prefix
- Persistence: 10Gi PVC
- Node Selector: `system: "true"`

### Prometheus
- Ingress: `/prometheus` (optional)
- Persistence: 50Gi PVC
- Retention: 30d
- Node Selector: `system: "true"`
- ServiceMonitor / PodMonitor / PrometheusRule selector fully open (any
  namespace, any label will be discovered). Business metric collection uses
  these resources:
    - `tools/llm/api/api-servicemonitor.yaml`     —— llm-api `/metrics`
    - `tools/llm/workers/vllm/vllm-servicemonitor.yaml` —— vLLM built-in metrics
    - DCGM exporter's built-in ServiceMonitor (Helm chart `serviceMonitor.enabled: true`)
- ⚠️ Note: `prometheus.io/*` annotations in Pod templates **do not work with kube-prometheus-stack**.
  These annotations are for "classic Prometheus + static scrape config", this project uses
  prometheus-operator mode, which only recognizes `ServiceMonitor` / `PodMonitor` CRD.

### DCGM Exporter
- Runtime Class: `nvidia`
- ServiceMonitor: Already enabled, auto-discovered by Prometheus
- Node Selector: `system: "true"` and `gpu-node: "true"`
