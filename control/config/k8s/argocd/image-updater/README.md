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
# 运行安装脚本
bash control/config/k8s/argocd/image-updater/install-image-updater.sh

# 或手动安装
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/manifests/install.yaml
```

### Step 2: 配置 Docker Registry 认证（如果需要）

如果使用私有 Docker registry，需要配置认证：

```bash
# 1. 编辑 docker-registry-secret.yaml，填入实际的 registry 信息
# 2. 应用 Secret
kubectl apply -f control/config/k8s/argocd/image-updater/docker-registry-secret.yaml
```

**占位符需要修改：**
- `YOUR_REGISTRY_URL`: 你的 registry 地址（如 `docker.io`, `ghcr.io`）
- `YOUR_USERNAME`: registry 用户名
- `YOUR_PASSWORD`: registry 密码或 token
- `BASE64_ENCODED_USERNAME:PASSWORD`: base64 编码的用户名:密码

**生成 base64 编码：**
```bash
echo -n 'username:password' | base64
```

### Step 3: 配置 Git 写回凭证

Image Updater 需要写回 Git 仓库，需要配置 Git 凭证：

```bash
# 1. 编辑 git-credentials-secret.yaml，填入实际的 GitHub 信息
# 2. 应用 Secret
kubectl apply -f control/config/k8s/argocd/image-updater/git-credentials-secret.yaml
```

**占位符需要修改：**
- `YOUR_GITHUB_USERNAME`: GitHub 用户名
- `YOUR_GITHUB_TOKEN`: GitHub Personal Access Token（需要 repo 写权限）
- `YOUR_EMAIL@example.com`: 用于 Git commit 的邮箱

**创建 GitHub Token：**
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
    argocd-image-updater.argoproj.io/image-list: llm-api=your-registry/llm-api
    argocd-image-updater.argoproj.io/llm-api.update-strategy: semver
    argocd-image-updater.argoproj.io/llm-api.allow-tags: regexp:^v?[0-9]+\.[0-9]+\.[0-9]+$
    argocd-image-updater.argoproj.io/write-back-method: git
    argocd-image-updater.argoproj.io/git-branch: main
```

## 文件说明

- `install-image-updater.sh`: 安装脚本
- `docker-registry-secret.yaml`: Docker registry 认证 Secret 模板
- `git-credentials-secret.yaml`: Git 写回凭证 Secret 模板
- `deployment-example.yaml`: Deployment 配置示例（带 Image Updater annotations）
- `README.md`: 本文件

## 更新策略

### semver（推荐）
- 匹配语义化版本号：`v1.2.3`, `1.2.3`, `v1.2.3-beta`
- 总是选择最新的版本号
- 适用于生产环境

### latest
- 总是使用 `latest` tag
- 简单但不推荐用于生产

### name
- 按名称排序，选择最新的
- 适用于自定义命名规则

### digest
- 使用 image digest（SHA256）
- 最安全但需要手动触发更新

## 验证

安装完成后，检查 Image Updater 状态：

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

