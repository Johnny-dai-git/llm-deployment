# Cleanup checklist: Files that can be deleted after Helm migration

⚠️ **Important**: Only delete these files after Helm chart deployment is successful and verified to be working.

## List of files that can be deleted

### Grafana-related files
```
tools/config/monitoring/grafana/grafana-deployment.yaml
tools/config/monitoring/grafana/grafana-service.yaml
tools/config/monitoring/grafana/grafana-ingress.yaml
tools/config/monitoring/grafana/grafana-pvc.yaml
tools/config/monitoring/grafana/grafana-datasource-configmap.yaml
tools/config/monitoring/grafana/grafana-admin-secret.yaml
```

### Prometheus-related files
```
tools/config/monitoring/prometheus/prometheus-deployment.yaml
tools/config/monitoring/prometheus/prometheus-service.yaml
tools/config/monitoring/prometheus/prometheus-configmap.yaml
tools/config/monitoring/prometheus/prometheus-pvc.yaml
tools/config/monitoring/prometheus/prometheus-serviceaccount.yaml
tools/config/monitoring/prometheus/prometheus-clusterrole.yaml
tools/config/monitoring/prometheus/prometheus-clusterrolebinding.yaml
```

### Exporter-related files
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

### ArgoCD Application (legacy)
```
tools/config/argocd-apps/monitoring-application.yaml
```

## Cleanup steps

### Step 1: Verify Helm deployment

```bash
# Check if all Pods are running normally
kubectl get pods -n monitoring

# Check if Grafana is accessible
kubectl get ingress -n monitoring

# Check if Prometheus is accessible
kubectl get svc -n monitoring | grep prometheus
```

### Step 2: Remove from kustomization.yaml

Edit `tools/config/monitoring/kustomization.yaml` and remove all references to the above resources.

### Step 3: Delete files

```bash
# Delete Grafana files
rm -f tools/config/monitoring/grafana/*.yaml

# Delete Prometheus files
rm -f tools/config/monitoring/prometheus/*.yaml

# Delete Exporters files (keep directory structure if needed later)
rm -f tools/config/monitoring/exporters/node-exporter.yaml
rm -f tools/config/monitoring/exporters/kube-state-metrics*.yaml
# Note: dcgm-exporter is managed by Helm but may need to keep custom configuration

# Delete old ArgoCD Application
rm -f tools/config/argocd-apps/monitoring-application.yaml
```

### Step 4: Update kustomization.yaml

If there are other resources in `kustomization.yaml` (e.g., custom dcgm-exporter configuration), create a simplified version:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: monitoring

resources:
  # List other resources that need to be retained
  # Example: custom dcgm-exporter configuration (if Helm chart does not meet requirements)
```

### Step 5: Commit changes

```bash
git add -A
git commit -m "Remove old YAML files after Helm migration"
git push
```

## Notes

1. **PVC data**: Deleting YAML files will not delete data in PVC. Helm chart will create new PVC; if data migration is needed, manual operation is required.

2. **dcgm-exporter**: If using Helm chart to manage dcgm-exporter, old YAML can be deleted. If Helm chart does not meet requirements, keep custom configuration.

3. **Backup**: It is recommended to backup the entire `monitoring` directory before deletion:
   ```bash
   cp -r tools/config/monitoring tools/config/monitoring.backup
   ```

4. **Verification**: After deleting files, ensure ArgoCD no longer attempts to sync these resources to avoid conflicts.

## Files to retain

The following files should be retained:

- `tools/helm/monitoring/kps-values.yaml` - Helm values configuration
- `tools/helm/monitoring/dcgm/values.yaml` - DCGM Helm values configuration
- `tools/config/argocd-apps/monitoring-helm-application.yaml` - New Helm Application
- `tools/config/argocd-apps/dcgm-helm-application.yaml` - DCGM Helm Application
