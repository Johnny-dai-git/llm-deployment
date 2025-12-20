# LLM Web Frontend

基于 nginx 的静态网页前端，用于 LLM Chat 界面。

## 目录结构

```
web/
├── Dockerfile          # Docker 构建文件
├── index.html          # 主页面（你可以修改）
├── README.md          # 说明文档
└── ...                # 其他静态文件（CSS, JS, 图片等）
```

## 如何修改网页

1. **修改 HTML**：编辑 `index.html` 文件
2. **添加 CSS**：创建 `style.css` 文件并在 HTML 中引用
3. **添加 JavaScript**：创建 `script.js` 文件并在 HTML 中引用
4. **添加图片**：将图片放在 `web/` 目录下，在 HTML 中引用

## 构建和部署

修改文件后，提交到 Git，工作流会自动：
1. 检测到 `web/**` 目录的变化
2. 构建 Docker 镜像
3. 推送到 `ghcr.io/Johnny-dai-git/llm-deployment/web:latest`
4. Kubernetes 会自动拉取新镜像并更新部署

## 本地测试

```bash
# 构建镜像
docker build -t llm-web:test ./web

# 运行容器
docker run -p 8080:80 llm-web:test

# 访问 http://localhost:8080
```

## API 集成

前端通过 `/api` 路径访问后端 API（由 Ingress 路由到 `llm-api-service`）。

当前 `index.html` 中的 API 调用示例：
```javascript
const API_BASE_URL = '/api';
// 调用 /api/v1/chat/completions
```

## 注意事项

- 所有静态文件都会被复制到 `/usr/share/nginx/html/` 目录
- 确保 `index.html` 在根目录，nginx 会默认提供它
- 如果需要自定义 nginx 配置，取消注释 Dockerfile 中的 `COPY nginx.conf` 行
