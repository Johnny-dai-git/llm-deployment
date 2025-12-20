# Web frontend image based on nginx
# You can modify HTML/CSS/JS files in this directory

FROM nginx:1.25-alpine

# Copy custom nginx configuration (if needed)
# COPY nginx.conf /etc/nginx/conf.d/default.conf

# Copy static files to nginx default directory
COPY . /usr/share/nginx/html/

# Expose port
EXPOSE 80

# nginx starts automatically, no CMD needed
