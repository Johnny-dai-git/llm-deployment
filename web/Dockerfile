# 基于 nginx 的 Web 前端镜像
# 你可以在这个目录下修改 HTML/CSS/JS 文件

FROM nginx:1.25-alpine

# 复制自定义的 nginx 配置（如果需要）
# COPY nginx.conf /etc/nginx/conf.d/default.conf

# 复制静态文件到 nginx 默认目录
COPY . /usr/share/nginx/html/

# 暴露端口
EXPOSE 80

# nginx 会自动启动，无需 CMD
