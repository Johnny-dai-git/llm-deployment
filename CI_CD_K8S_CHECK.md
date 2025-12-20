# CI/CD 和 K8s 配置匹配检查报告

## ✅ 已匹配的配置

### 1. Gateway / LLM-API
- **CI 构建**: `ghcr.io/Johnny-dai-git/llm-deployment/gateway`
- **K8s 使用**: `ghcr.io/Johnny-dai-git/llm-deployment/gateway:latest` ✅
- **imagePullSecrets**: ✅ 已配置
- **ArgoCD Image Updater**: ✅ 已配置

### 2. Router
- **CI 构建**: `ghcr.io/Johnny-dai-git/llm-deployment/router`
- **K8s 使用**: `ghcr.io/Johnny-dai-git/llm-deployment/router:latest` ✅
- **imagePullSecrets**: ✅ 已配置
- **ArgoCD Image Updater**: ✅ 已配置

### 3. VLLM Worker
- **CI 构建**: `ghcr.io/Johnny-dai-git/llm-deployment/vllm-worker`
- **K8s 使用**: `ghcr.io/Johnny-dai-git/llm-deployment/vllm-worker:latest` ✅
- **imagePullSecrets**: ✅ 已配置
- **ArgoCD Image Updater**: ✅ 已配置

### 4. TRT Worker
- **CI 构建**: `ghcr.io/Johnny-dai-git/llm-deployment/trt-worker`
- **K8s 使用**: `ghcr.io/Johnny-dai-git/llm-deployment/trt-worker:latest` ✅
- **imagePullSecrets**: ✅ 已配置
- **ArgoCD Image Updater**: ✅ 已配置

### 5. Web
- **CI 构建**: `ghcr.io/Johnny-dai-git/llm-deployment/web`
- **K8s 使用**: `ghcr.io/Johnny-dai-git/llm-deployment/web:latest` ✅
- **imagePullSecrets**: ✅ 已配置
- **ArgoCD Image Updater**: ✅ 已配置

## ❌ 发现的问题

### 1. system/ 目录下的部署文件
这些文件看起来是旧版本或备用配置：

#### gateway-deploy.yaml
- **镜像**: ✅ `ghcr.io/Johnny-dai-git/llm-deployment/gateway:latest`
- **imagePullSecrets**: ✅ 已配置
- **ArgoCD Image Updater**: ❌ 缺失
- **nodeSelector**: ⚠️ 使用 `role: system`（应该使用 `system: "true"`）

#### router-deploy.yaml
- **镜像**: ✅ `ghcr.io/Johnny-dai-git/llm-deployment/router:latest`
- **imagePullSecrets**: ✅ 已配置
- **ArgoCD Image Updater**: ❌ 缺失
- **nodeSelector**: ⚠️ 使用 `role: system`（应该使用 `system: "true"`）

#### worker-gpu-deploy.yaml
- **镜像**: ✅ `ghcr.io/Johnny-dai-git/llm-deployment/vllm-worker:latest`
- **imagePullSecrets**: ✅ 已配置
- **ArgoCD Image Updater**: ❌ 缺失
- **nodeSelector**: ⚠️ 使用 `role: gpu`（应该使用 `gpu-node: "true"`）

## 📋 建议

1. **system/ 目录**: 
   - 如果这些是备用配置，建议添加 ArgoCD Image Updater 配置
   - 统一 nodeSelector 标签（与 control/config/k8s/ 目录保持一致）
3. **所有部署文件**: 确保都使用 `ghcr.io` 镜像并配置了 `imagePullSecrets`
