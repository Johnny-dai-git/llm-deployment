# 清理清单：Helm 迁移后可删除的文件

⚠️ **重要提示**：只有在 Helm chart 部署成功并验证正常工作后，才删除这些文件。

## 可以删除的文件列表

### Grafana 相关文件
```
tools/config/monitoring/grafana/grafana-deployment.yaml
tools/config/monitoring/grafana/grafana-service.yaml
tools/config/monitoring/grafana/grafana-ingress.yaml
tools/config/monitoring/grafana/grafana-pvc.yaml
tools/config/monitoring/grafana/grafana-datasource-configmap.yaml
tools/config/monitoring/grafana/grafana-admin-secret.yaml
```

### Prometheus 相关文件
```
tools/config/monitoring/prometheus/prometheus-deployment.yaml
tools/config/monitoring/prometheus/prometheus-service.yaml
tools/config/monitoring/prometheus/prometheus-configmap.yaml
tools/config/monitoring/prometheus/prometheus-pvc.yaml
tools/config/monitoring/prometheus/prometheus-serviceaccount.yaml
tools/config/monitoring/prometheus/prometheus-clusterrole.yaml
tools/config/monitoring/prometheus/prometheus-clusterrolebinding.yaml
```

### Exporters 相关文件
```
tools/config/monitoring/exporters/node-exporter.yaml
tools/config/monitoring/exporters/kube-state-metrics.yaml
tools/config/monitoring/exporters/kube-state-metrics-service.yaml
tools/config/monitoring/exporters/kube-state-metrics-serviceaccount.yaml
tools/config/monitoring/exporters/kube-state-metrics-clusterrole.yaml
tools/config/monitoring/exporters/kube-state-metrics-clusterrolebinding.yaml
tools/config/monitoring/exporters/dcgm-exporter.yaml
tools/config/monitoring/exporters/dcgm-exporter-service.yaml
```

### ArgoCD Application（旧的）
```
tools/config/argocd-apps/monitoring-application.yaml
```

## 清理步骤

### Step 1: 验证 Helm 部署

```bash
# 检查所有 Pod 是否运行正常
kubectl get pods -n monitoring

# 检查 Grafana 是否可以访问
kubectl get ingress -n monitoring

# 检查 Prometheus 是否可以访问
kubectl get svc -n monitoring | grep prometheus
```

### Step 2: 从 kustomization.yaml 中移除

编辑 `tools/config/monitoring/kustomization.yaml`，移除所有上述资源的引用。

### Step 3: 删除文件

```bash
# 删除 Grafana 文件
rm -f tools/config/monitoring/grafana/*.yaml

# 删除 Prometheus 文件
rm -f tools/config/monitoring/prometheus/*.yaml

# 删除 Exporters 文件（保留目录结构，如果以后需要）
rm -f tools/config/monitoring/exporters/node-exporter.yaml
rm -f tools/config/monitoring/exporters/kube-state-metrics*.yaml
# 注意：dcgm-exporter 由 Helm 管理，但可能需要保留自定义配置

# 删除旧的 ArgoCD Application
rm -f tools/config/argocd-apps/monitoring-application.yaml
```

### Step 4: 更新 kustomization.yaml

如果 `kustomization.yaml` 中还有其他资源（如 dcgm-exporter 的自定义配置），可以创建一个新的简化版本：

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: monitoring

resources:
  # 如果有其他需要保留的资源，在这里列出
  # 例如：自定义的 dcgm-exporter 配置（如果 Helm chart 不满足需求）
```

### Step 5: 提交更改

```bash
git add -A
git commit -m "Remove old YAML files after Helm migration"
git push
```

## 注意事项

1. **PVC 数据**：删除 YAML 文件不会删除 PVC 中的数据。Helm chart 会创建新的 PVC，如果需要迁移数据，需要手动操作。

2. **dcgm-exporter**：如果使用 Helm chart 管理 dcgm-exporter，可以删除旧的 YAML。如果 Helm chart 不满足需求，可以保留自定义配置。

3. **备份**：建议在删除前先备份整个 `monitoring` 目录：
   ```bash
   cp -r tools/config/monitoring tools/config/monitoring.backup
   ```

4. **验证**：删除文件后，确保 ArgoCD 不再尝试同步这些资源，避免冲突。

## 保留的文件

以下文件应该保留：

- `tools/helm/monitoring/kps-values.yaml` - Helm values 配置
- `tools/helm/monitoring/dcgm/values.yaml` - DCGM Helm values 配置
- `tools/config/argocd-apps/monitoring-helm-application.yaml` - 新的 Helm Application
- `tools/config/argocd-apps/dcgm-helm-application.yaml` - DCGM Helm Application
