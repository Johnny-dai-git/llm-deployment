# ArgoCD Image Updater 配置说明

## 概述

ArgoCD Image Updater 可以自动监控 Docker registry 中的新 image，并自动更新 Git 仓库中的 YAML 文件，实现完全自动化的 CI/CD 流程。

## 工作流程

```
1. CI build 完成
2. Push 新的 Docker image 到 registry (例如: your-registry/llm-api:v1.2.3)
3. ArgoCD Image Updater 检测到新 image
4. Image Updater 自动更新 Git 仓库中的 YAML 文件 (修改 image tag)
5. ArgoCD 检测到 Git 变化 → 自动同步部署 ✅
```

## 安装步骤

### Step 1: 安装 ArgoCD Image Updater

```bash
# 通过 run_control 脚本安装（推荐）
# 脚本会自动安装 ArgoCD Image Updater 并配置所有必要的 Secret

# 或手动安装（使用 Helm）
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm upgrade --install argocd-image-updater argo/argocd-image-updater \
  -n argocd \
  --create-namespace \
  -f control/config/k8s/argocd/image-updater/values.yaml

# 或使用原始 manifest 安装
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/manifests/install.yaml
```

### Step 2: 配置 Docker Registry 认证（如果需要）

如果使用私有 Docker registry，需要配置认证：

```bash
# 1. 编辑 docker-registry-secret.yaml，填入实际的 registry 信息
# 2. 应用 Secret
kubectl apply -f control/config/k8s/argocd/image-updater/docker-registry-secret.yaml
```

**注意：**
- 如果 Secret 文件已包含实际配置，则无需修改
- 如果需要修改，请编辑 `docker-registry-secret.yaml` 文件
- Secret 类型为 `kubernetes.io/dockerconfigjson`，格式为标准的 Docker config JSON

### Step 3: 配置 Git 写回凭证

Image Updater 需要写回 Git 仓库，需要配置 Git 凭证：

```bash
# 1. 编辑 git-credentials-secret.yaml，填入实际的 GitHub 信息
# 2. 应用 Secret
kubectl apply -f control/config/k8s/argocd/image-updater/git-credentials-secret.yaml
```

**注意：**
- 如果 Secret 文件已包含实际配置，则无需修改
- 如果需要修改，请编辑 `git-credentials-secret.yaml` 文件
- Secret 包含 `username` 和 `password` 字段（password 为 GitHub Personal Access Token）

**创建 GitHub Token（如果需要）：**
1. GitHub -> Settings -> Developer settings -> Personal access tokens -> Tokens (classic)
2. Generate new token (classic)
3. 选择权限：`repo`（完整仓库访问）
4. 复制生成的 token

### Step 4: 在 Deployment 中添加 Image Updater Annotations

参考 `deployment-example.yaml`，在需要自动更新的 Deployment 中添加 annotations。

**示例（llm-api）：**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llm-api
  namespace: llm
  annotations:
    argocd-image-updater.argoproj.io/image-list: llm-api=ghcr.io/johnny-dai-git/llm-deployment/gateway
    argocd-image-updater.argoproj.io/llm-api.update-strategy: name
    argocd-image-updater.argoproj.io/llm-api.allow-tags: regexp:^v-[0-9]{8}-[0-9]{6}$
    argocd-image-updater.argoproj.io/write-back-method: git:secret:argocd/git-credentials
    argocd-image-updater.argoproj.io/git-branch: main
```

## 文件说明

- `values.yaml`: Helm chart 配置文件（用于通过 Helm 安装）
- `docker-registry-secret.yaml`: Docker registry 认证 Secret（用于 Image Updater 拉取镜像元数据）
- `git-credentials-secret.yaml`: Git 写回凭证 Secret（用于 Image Updater 写回 Git 仓库）
- `deployment-example.yaml`: Deployment 配置示例（带 Image Updater annotations）
- `validate-config.sh`: 配置验证脚本（验证配置文件是否正确）
- `test-integration.sh`: 集成测试脚本（测试 Image Updater 是否能正常工作）
- `README.md`: 本文件

## 更新策略

### name（当前使用）
- 按名称排序，选择最新的
- 适用于自定义命名规则（如时间戳格式：`v-20240101-120000`）
- 当前部署使用此策略，tag 模式：`^v-[0-9]{8}-[0-9]{6}$`

### semver（推荐用于语义化版本）
- 匹配语义化版本号：`v1.2.3`, `1.2.3`, `v1.2.3-beta`
- 总是选择最新的版本号
- 适用于使用语义化版本号的环境
- tag 模式示例：`^v?[0-9]+\.[0-9]+\.[0-9]+$`

### latest
- 总是使用 `latest` tag
- 简单但不推荐用于生产环境

### digest
- 使用 image digest（SHA256）
- 最安全但需要手动触发更新

## 验证和测试

### 配置验证

在部署前，验证配置文件是否正确：

```bash
# 运行配置验证脚本
bash control/config/k8s/argocd/image-updater/validate-config.sh
```

此脚本会检查：
- Helm values.yaml 配置完整性
- Secret 文件格式和内容
- Deployment 示例配置
- 实际 Deployment 文件中的 annotations
- YAML 语法正确性

### 集成测试

部署后，测试 Image Updater 是否能正常工作：

```bash
# 运行集成测试脚本
bash control/config/k8s/argocd/image-updater/test-integration.sh
```

此脚本会检查：
- Image Updater Deployment 状态
- Pod 运行状态
- 必要的 Secret 是否存在
- Image Updater 日志
- ArgoCD Applications 配置
- Registry 连通性

### 手动验证

安装完成后，也可以手动检查 Image Updater 状态：

```bash
# 检查 Pod 状态
kubectl get pods -n argocd | grep image-updater

# 查看日志
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-image-updater

# 查看 Application 状态（在 ArgoCD UI 中）
# http://149.165.147.30/argocd
```

## 故障排查

1. **Image Updater 无法检测新 image**
   - 检查 registry 认证是否正确
   - 检查 image 路径是否正确
   - 查看 Image Updater 日志

2. **无法写回 Git**
   - 检查 Git 凭证是否正确
   - 检查 Token 是否有写权限
   - 查看 Image Updater 日志

3. **ArgoCD 没有自动同步**
   - 检查 Application 的 `syncPolicy.automated` 是否启用
   - 检查 Git 仓库是否有变化

## 参考文档

- [ArgoCD Image Updater 官方文档](https://argocd-image-updater.readthedocs.io/)
- [ArgoCD 官方文档](https://argo-cd.readthedocs.io/)

