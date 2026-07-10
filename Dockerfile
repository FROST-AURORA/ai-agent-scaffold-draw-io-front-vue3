FROM nginx:alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY dist/ /usr/share/nginx/html/

EXPOSE 80

CMD ["/bin/sh", "-c", "printf 'window.__ENV = { NEXT_PUBLIC_API_BASE_URL: \"%s\" };\\n' \"${NEXT_PUBLIC_API_BASE_URL:-/api/v1}\" > /usr/share/nginx/html/env-config.js && nginx -g 'daemon off;'"]
