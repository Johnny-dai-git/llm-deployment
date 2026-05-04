# Monitoring Helm Charts

本目录包含使用 Helm 管理监控组件的配置文件。

## 文件说明

- `kps-values.yaml`: kube-prometheus-stack 的 Helm values 配置
- `dcgm/values.yaml`: dcgm-exporter 的 Helm values 配置

## 迁移步骤

### Step 0: 停用现有 YAML Application

在 ArgoCD UI 中：
1. 找到 `llm-platform-monitoring` Application
2. 点击 "Delete"（不要勾选 "Cascade"）
3. 这样会停止管理旧资源，但不会删除它们

### Step 1: 应用新的 Helm Applications

```bash
# 应用 kube-prometheus-stack
kubectl apply -f tools/config/argocd-apps/monitoring-helm-application.yaml

# 应用 dcgm-exporter
kubectl apply -f tools/config/argocd-apps/dcgm-helm-application.yaml
```

### Step 2: 在 ArgoCD UI 中同步

1. 打开 ArgoCD UI
2. 找到新创建的 Applications：
   - `llm-platform-monitoring-helm`
   - `dcgm-exporter-helm`
3. 点击 "Sync" 按钮

### Step 3: 验证

```bash
# 检查 Pod 状态
kubectl get pods -n monitoring

# 检查 Grafana
kubectl get ingress -n monitoring

# 访问 Grafana
# http://<hostNetwork-IP>/grafana
# 用户名: admin
# 密码: admin
```

## 本地测试（可选）

如果想在应用 ArgoCD 之前本地测试：

```bash
# 添加 Helm 仓库
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add nvidia https://nvidia.github.io/dcgm-exporter/helm-charts
helm repo update

# 安装 kube-prometheus-stack
helm install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f tools/helm/monitoring/kps-values.yaml

# 安装 dcgm-exporter
helm install dcgm nvidia/dcgm-exporter \
  -n monitoring \
  -f tools/helm/monitoring/dcgm/values.yaml
```

## 清理旧资源（可选）

等 Helm chart 部署成功并验证后，可以手动清理旧资源：

```bash
# 只删除旧的 Deployment/Service/Ingress，保留 PVC
kubectl delete deploy grafana prometheus -n monitoring --ignore-not-found
kubectl delete svc grafana prometheus -n monitoring --ignore-not-found
kubectl delete ingress grafana-ingress -n monitoring --ignore-not-found
```

## 配置说明

### Grafana
- 子路径: `/grafana`
- Ingress: 使用 nginx，保留 `/grafana` 前缀
- Persistence: 10Gi PVC
- Node Selector: `system: "true"`

### Prometheus
- Ingress: `/prometheus`（可选）
- Persistence: 50Gi PVC
- Retention: 30d
- Node Selector: `system: "true"`
- ServiceMonitor / PodMonitor / PrometheusRule selector 全部放开（任意
  namespace、任意 label 都会被发现）。业务指标采集靠下面这些资源:
    - `tools/llm/api/api-servicemonitor.yaml`     —— llm-api `/metrics`
    - `tools/llm/workers/vllm/vllm-servicemonitor.yaml` —— vLLM 内置指标
    - DCGM exporter 自带的 ServiceMonitor (Helm chart `serviceMonitor.enabled: true`)
- ⚠️ 注意:Pod 模板里的 `prometheus.io/*` annotation **对 kube-prometheus-stack
  不生效**。这些 annotation 是给"经典 Prometheus + 静态 scrape config"用的,
  本项目用的是 prometheus-operator 模式,只认 `ServiceMonitor` / `PodMonitor` CRD。

### DCGM Exporter
- Runtime Class: `nvidia`
- ServiceMonitor: 已启用，自动被 Prometheus 发现
- Node Selector: `system: "true"` 和 `gpu-node: "true"`
