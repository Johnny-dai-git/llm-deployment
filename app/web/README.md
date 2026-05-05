# LLM Web Frontend

Static web frontend based on nginx for LLM Chat interface.

## Directory structure

```
web/
├── Dockerfile          # Docker build file
├── index.html          # Main page (you can modify)
├── README.md          # Documentation
└── ...                # Other static files (CSS, JS, images, etc.)
```

## How to Modify the Web Page

1. **Modify HTML**: Edit `index.html` file
2. **Add CSS**: Create `style.css` file and reference it in HTML
3. **Add JavaScript**: Create `script.js` file and reference it in HTML
4. **Add Images**: Place images in `web/` directory and reference in HTML

## Build and Deploy

After modifying files, commit to Git, the workflow will automatically:
1. Detect changes in `app/web/**` directory
2. Build Docker image
3. Push to `ghcr.io/johnny-dai-git/llm-deployment/web:latest`
4. Kubernetes will automatically pull the new image and update deployment

## Local Testing

```bash
# Build image
docker build -t llm-web:test ./app/web

# Run container
docker run -p 8080:80 llm-web:test

# Access http://localhost:8080
```

## API Integration

Frontend accesses `/api` path to access backend API (routed by Ingress to `api-gateway-service`).

Current `index.html` API call example:
```javascript
const API_BASE_URL = '/api';
// Call /api/v1/chat/completions
```

## Notes

- All static files will be copied to `/usr/share/nginx/html/` directory
- Ensure `index.html` is in root directory, nginx will serve it by default
- If you need custom nginx configuration, uncomment the `COPY nginx.conf` line
