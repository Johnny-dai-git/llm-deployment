#!/bin/bash
# Cleanup script: Delete old YAML files after Helm migration
# ⚠️ Warning: Only run this script after Helm chart deployment is successful and verified to work

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
MONITORING_DIR="${REPO_DIR}/tools/config/monitoring"

echo "⚠️  Warning: This script will delete old YAML files"
echo "Make sure Helm chart has been successfully deployed and is working"
echo ""
read -p "Continue? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
  echo "Cancelled"
  exit 0
fi

echo "Starting cleanup..."

# Backup directory
echo ">>> Creating backup..."
BACKUP_DIR="${MONITORING_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
cp -r "${MONITORING_DIR}" "${BACKUP_DIR}"
echo "✔ Backup created: ${BACKUP_DIR}"

# Delete Grafana files
echo ">>> Deleting Grafana files..."
rm -f "${MONITORING_DIR}/grafana/grafana-deployment.yaml"
rm -f "${MONITORING_DIR}/grafana/grafana-service.yaml"
rm -f "${MONITORING_DIR}/grafana/grafana-ingress.yaml"
rm -f "${MONITORING_DIR}/grafana/grafana-pvc.yaml"
rm -f "${MONITORING_DIR}/grafana/grafana-datasource-configmap.yaml"
rm -f "${MONITORING_DIR}/grafana/grafana-admin-secret.yaml"
echo "✔ Grafana files deleted"

# Delete Prometheus files
echo ">>> Deleting Prometheus files..."
rm -f "${MONITORING_DIR}/prometheus/prometheus-deployment.yaml"
rm -f "${MONITORING_DIR}/prometheus/prometheus-service.yaml"
rm -f "${MONITORING_DIR}/prometheus/prometheus-configmap.yaml"
rm -f "${MONITORING_DIR}/prometheus/prometheus-pvc.yaml"
rm -f "${MONITORING_DIR}/prometheus/prometheus-serviceaccount.yaml"
rm -f "${MONITORING_DIR}/prometheus/prometheus-clusterrole.yaml"
rm -f "${MONITORING_DIR}/prometheus/prometheus-clusterrolebinding.yaml"
echo "✔ Prometheus files deleted"

# Delete Exporters files
echo ">>> Deleting Exporters files..."
rm -f "${MONITORING_DIR}/exporters/node-exporter.yaml"
rm -f "${MONITORING_DIR}/exporters/kube-state-metrics.yaml"
rm -f "${MONITORING_DIR}/exporters/kube-state-metrics-service.yaml"
rm -f "${MONITORING_DIR}/exporters/kube-state-metrics-serviceaccount.yaml"
rm -f "${MONITORING_DIR}/exporters/kube-state-metrics-clusterrole.yaml"
rm -f "${MONITORING_DIR}/exporters/kube-state-metrics-clusterrolebinding.yaml"
# Note: dcgm-exporter is managed by Helm, delete old files
rm -f "${MONITORING_DIR}/exporters/dcgm-exporter.yaml"
rm -f "${MONITORING_DIR}/exporters/dcgm-exporter-service.yaml"
echo "✔ Exporters files deleted"

# Update kustomization.yaml (clear or keep only necessary resources)
echo ">>> Updating kustomization.yaml..."
cat > "${MONITORING_DIR}/kustomization.yaml" << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: monitoring

resources:
  # All monitoring components are now managed by Helm chart
  # List other custom resources that need to be retained here
EOF
echo "✔ kustomization.yaml updated"

# Delete old ArgoCD Application
echo ">>> Deleting old ArgoCD Application..."
rm -f "${REPO_DIR}/tools/config/argocd-apps/monitoring-application.yaml"
echo "✔ Old ArgoCD Application deleted"

echo ""
echo "✅ Cleanup complete!"
echo ""
echo "Next steps:"
echo "1. Check Git status: git status"
echo "2. Commit changes: git add -A && git commit -m 'Remove old YAML files after Helm migration'"
echo "3. Push: git push"
echo ""
echo "Backup location: ${BACKUP_DIR}"
