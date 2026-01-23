# CI/CD 和 K8s 资源部署配置总结

## ✅ 已完成的修改

### 1. 创建 Ingress 资源（按 namespace 拆分）
- **LLM Ingress**: `llm/ingress/llm-ingress.yaml`
  - **Namespace**: `llm`
  - **路由**:
    - `/` → LLM Web (`llm-web-service`)
    - `/api` → LLM API (`llm-api-service`)
- **Grafana Ingress**: `monitoring/grafana/grafana-ingress.yaml`
  - **Namespace**: `monitoring`
  - **路由**:
    - `/grafana` → Grafana (`grafana`)
- **注意**: Ingress 不能跨 namespace 引用 Service，因此必须按 namespace 拆分

### 2. 添加 Image Updater Annotations
- **文件**: 所有 Deployment 文件
  - `llm/api/llm-api-deployment.yaml`
  - `llm/router/router-deployment.yaml`
  - `llm/workers/vllm/vllm-worker-deployment.yaml`
  - `llm/workers/trt/trt-worker-deployment.yaml`
- **功能**: 自动检测新 Docker image 并更新 Git 仓库
- **注意**: 需要将 `YOUR_REGISTRY` 替换为实际的 registry 地址

### 3. 更新 run_control 脚本
- **修改**:
  - ✅ 添加 ArgoCD Image Updater 安装步骤（Step 6）
  - ✅ 移除手动部署步骤（原 Step 6-11）
  - ✅ 所有服务现在由 ArgoCD 从 Git 同步部署
- **流程**: 完全 GitOps，所有服务由 ArgoCD 管理

### 4. 创建 ArgoCD basehref ConfigMap（可选）
- **文件**: `argocd/argocd-basehref-configmap.yaml`
- **功能**: 如果 ArgoCD 访问有问题，可以应用此配置

## 📋 部署流程

### 当前工作流程

```
1. 运行 run_control 脚本
   ↓
2. 部署基础设施（MetalLB, ingress-nginx, ArgoCD）
   ↓
3. 安装 ArgoCD Image Updater
   ↓
4. 创建 ArgoCD Applications（从 Git 同步）
   ↓
5. ArgoCD 自动从 Git 仓库同步部署所有服务
   ↓
6. 服务运行中...
```

### CI/CD 工作流程（使用 Image Updater）

```
开发者提交代码
   ↓
CI (本地 laptop):
  1. Build Docker image
  2. Push to registry (例如: your-registry/llm-api:v1.2.3)
  3. ✅ 完成！不需要修改 YAML
   ↓
ArgoCD Image Updater:
  1. 检测到新 image (v1.2.3)
  2. 自动更新 Git 仓库中的 YAML (修改 image tag)
  3. Commit & Push 到 Git
   ↓
ArgoCD:
  1. 检测到 Git 变化
  2. 自动同步部署 ✅
```

## 🔧 需要配置的内容

### 1. Image Updater Registry 配置（如需要）

编辑 `argocd/image-updater/docker-registry-secret.yaml`:
- `YOUR_REGISTRY_URL`: 你的 registry 地址
- `YOUR_USERNAME`: registry 用户名
- `YOUR_PASSWORD`: registry 密码或 token

应用配置：
```bash
kubectl apply -f config/k8s/argocd-image-updater/image-updater/docker-registry-secret.yaml
```

### 2. Image Updater Git 凭证配置（必须）

编辑 `argocd-image-updater/image-updater/git-credentials-secret.yaml`:
- `YOUR_GITHUB_USERNAME`: GitHub 用户名
- `YOUR_GITHUB_TOKEN`: GitHub Personal Access Token（需要 repo 写权限）
- `YOUR_EMAIL@example.com`: 用于 Git commit 的邮箱

应用配置：
```bash
kubectl apply -f config/k8s/argocd-image-updater/image-updater/git-credentials-secret.yaml
```

### 3. 更新 Deployment 中的 Registry 地址

在所有 Deployment 文件中，将 `YOUR_REGISTRY` 替换为实际的 registry 地址：
- `llm-api-deployment.yaml`
- `router-deployment.yaml`
- `vllm-worker-deployment.yaml`
- `trt-worker-deployment.yaml`

例如：
```yaml
argocd-image-updater.argoproj.io/image-list: llm-api=your-registry.com/llm-api
```

## 🌐 服务访问地址

部署完成后，通过以下地址访问服务：

- **LLM Web**: `http://149.165.147.30/`
- **LLM API**: `http://149.165.147.30/api`
- **Grafana**: `http://149.165.147.30/grafana`
- **ArgoCD**: `http://149.165.147.30/argocd`

## 📝 重要提示

1. **首次部署**:
   - 确保 Git 仓库包含所有 YAML 文件
   - 运行 `run_control` 脚本
   - 在 ArgoCD UI 中检查 Applications 同步状态

2. **后续更新**:
   - CI 只需 build 和 push Docker image
   - Image Updater 会自动更新 Git 并触发部署
   - 无需手动操作

3. **故障排查**:
   - 检查 ArgoCD Applications 状态: `kubectl get applications -n argocd`
   - 查看 Image Updater 日志: `kubectl logs -n argocd -l app.kubernetes.io/name=argocd-image-updater`
   - 检查 Ingress: `kubectl get ingress -A`

## 🎯 下一步

1. ✅ 配置 Docker Registry Secret（如需要）
2. ✅ 配置 Git 凭证 Secret（必须）
3. ✅ 更新 Deployment 中的 registry 地址
4. ✅ 确保 Git 仓库包含所有 YAML 文件
5. ✅ 运行 `run_control` 脚本进行部署

