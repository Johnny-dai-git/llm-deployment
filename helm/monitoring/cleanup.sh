#!/bin/bash
# 清理脚本：删除 Helm 迁移后的旧 YAML 文件
# ⚠️ 警告：只有在 Helm chart 部署成功并验证正常工作后，才运行此脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
MONITORING_DIR="${REPO_DIR}/tools/config/monitoring"

echo "⚠️  警告：此脚本将删除旧的 YAML 文件"
echo "请确保 Helm chart 已成功部署并正常工作"
echo ""
read -p "是否继续？(yes/no): " confirm

if [ "$confirm" != "yes" ]; then
  echo "已取消"
  exit 0
fi

echo "开始清理..."

# 备份目录
echo ">>> 创建备份..."
BACKUP_DIR="${MONITORING_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
cp -r "${MONITORING_DIR}" "${BACKUP_DIR}"
echo "✔ 备份已创建: ${BACKUP_DIR}"

# 删除 Grafana 文件
echo ">>> 删除 Grafana 文件..."
rm -f "${MONITORING_DIR}/grafana/grafana-deployment.yaml"
rm -f "${MONITORING_DIR}/grafana/grafana-service.yaml"
rm -f "${MONITORING_DIR}/grafana/grafana-ingress.yaml"
rm -f "${MONITORING_DIR}/grafana/grafana-pvc.yaml"
rm -f "${MONITORING_DIR}/grafana/grafana-datasource-configmap.yaml"
rm -f "${MONITORING_DIR}/grafana/grafana-admin-secret.yaml"
echo "✔ Grafana 文件已删除"

# 删除 Prometheus 文件
echo ">>> 删除 Prometheus 文件..."
rm -f "${MONITORING_DIR}/prometheus/prometheus-deployment.yaml"
rm -f "${MONITORING_DIR}/prometheus/prometheus-service.yaml"
rm -f "${MONITORING_DIR}/prometheus/prometheus-configmap.yaml"
rm -f "${MONITORING_DIR}/prometheus/prometheus-pvc.yaml"
rm -f "${MONITORING_DIR}/prometheus/prometheus-serviceaccount.yaml"
rm -f "${MONITORING_DIR}/prometheus/prometheus-clusterrole.yaml"
rm -f "${MONITORING_DIR}/prometheus/prometheus-clusterrolebinding.yaml"
echo "✔ Prometheus 文件已删除"

# 删除 Exporters 文件
echo ">>> 删除 Exporters 文件..."
rm -f "${MONITORING_DIR}/exporters/node-exporter.yaml"
rm -f "${MONITORING_DIR}/exporters/kube-state-metrics.yaml"
rm -f "${MONITORING_DIR}/exporters/kube-state-metrics-service.yaml"
rm -f "${MONITORING_DIR}/exporters/kube-state-metrics-serviceaccount.yaml"
rm -f "${MONITORING_DIR}/exporters/kube-state-metrics-clusterrole.yaml"
rm -f "${MONITORING_DIR}/exporters/kube-state-metrics-clusterrolebinding.yaml"
# 注意：dcgm-exporter 由 Helm 管理，删除旧文件
rm -f "${MONITORING_DIR}/exporters/dcgm-exporter.yaml"
rm -f "${MONITORING_DIR}/exporters/dcgm-exporter-service.yaml"
echo "✔ Exporters 文件已删除"

# 更新 kustomization.yaml（清空或只保留必要的资源）
echo ">>> 更新 kustomization.yaml..."
cat > "${MONITORING_DIR}/kustomization.yaml" << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: monitoring

resources:
  # 所有监控组件现在由 Helm chart 管理
  # 如果有其他自定义资源需要保留，在这里列出
EOF
echo "✔ kustomization.yaml 已更新"

# 删除旧的 ArgoCD Application
echo ">>> 删除旧的 ArgoCD Application..."
rm -f "${REPO_DIR}/tools/config/argocd-apps/monitoring-application.yaml"
echo "✔ 旧的 ArgoCD Application 已删除"

echo ""
echo "✅ 清理完成！"
echo ""
echo "下一步："
echo "1. 检查 Git 状态: git status"
echo "2. 提交更改: git add -A && git commit -m 'Remove old YAML files after Helm migration'"
echo "3. 推送: git push"
echo ""
echo "备份位置: ${BACKUP_DIR}"
