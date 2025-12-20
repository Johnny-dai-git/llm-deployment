# LLM Web Frontend

Static web frontend based on nginx for LLM Chat interface.

## 目录结构

```
web/
├── Dockerfile          # Docker build file
├── index.html          # Main page (you can modify)
├── README.md          # Documentation
└── ...                # Other static files (CSS, JS, images, etc.)
```

## How to Modify the Web Page

1. **Modify HTML**: Edit `index.html` 文件
2. **Add CSS**: Create `style.css` 文件并在 HTML 中引用
3. **Add JavaScript**: Create `script.js` 文件并在 HTML 中引用
4. **Add Images**: Place images in `web/` 目录下，在 HTML 中引用

## Build and Deploy

After modifying files, commit to Git, the workflow will automatically:
1. Detect changes in `web/**` 目录的变化
2. Build Docker image
3. Push to `ghcr.io/johnny-dai-git/llm-deployment/web:latest`
4. Kubernetes will automatically pull the new image and update deployment

## Local Testing

```bash
# Build image
docker build -t llm-web:test ./web

# Run container
docker run -p 8080:80 llm-web:test

# Access http://localhost:8080
```

## API Integration

## Frontend accesses `/api` 路径访问后端 API（由 Ingress 路由到 `llm-api-service`）。

## Current `index.html` 中的 API 调用示例：
```javascript
const API_BASE_URL = '/api';
// 调用 /api/v1/chat/completions
```

## Notes

- All static files will be copied to `/usr/share/nginx/html/` 目录
- Ensure `index.html` 在根目录，nginx 会默认提供它
- If you need custom nginx configuration, uncomment the `COPY nginx.conf` 行
