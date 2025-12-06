#!/bin/bash
# =========================
# ArgoCD Image Updater 安装脚本（占位符）
# =========================
# 注意：这是占位符脚本，需要根据实际情况配置

set -e

echo "================ Step: Install ArgoCD Image Updater ==================="

# Step 1: 安装 ArgoCD Image Updater
echo ">>> 安装 ArgoCD Image Updater..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/manifests/install.yaml

# Step 2: 等待 Image Updater 就绪
echo ">>> 等待 ArgoCD Image Updater 就绪..."
sleep 10

# Step 3: 检查状态
echo ">>> 检查 ArgoCD Image Updater 状态..."
kubectl get pods -n argocd | grep image-updater || echo "⚠ Image Updater 可能还未就绪"

echo ""
echo "=========================================================="
echo "📝 下一步："
echo "1. 配置 Docker Registry 认证（如果需要私有仓库）"
echo "   kubectl apply -f config/k8s/argocd/image-updater/docker-registry-secret.yaml"
echo ""
echo "2. 配置 Git 写回凭证（Image Updater 需要写回 Git）"
echo "   kubectl apply -f config/k8s/argocd/image-updater/git-credentials-secret.yaml"
echo ""
echo "3. 在 Deployment YAML 中添加 Image Updater annotations"
echo "   参考: config/k8s/argocd/image-updater/deployment-example.yaml"
echo "=========================================================="

