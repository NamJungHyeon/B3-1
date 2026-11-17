#!/bin/bash
# EC2 최초 부팅 시 실행: Nginx 설치 + 고정 페이지(/) + 헬스체크(/health)
set -euxo pipefail
dnf install -y nginx

cat > /usr/share/nginx/html/index.html <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><title>B3-1</title></head>
<body><h1>Hello Cloud - B3-1</h1><p>Served by Nginx on EC2 (ap-northeast-2)</p></body></html>
HTML

cat > /etc/nginx/default.d/health.conf <<'CONF'
location = /health {
    default_type text/plain;
    return 200 "OK\n";
}
CONF

nginx -t
systemctl enable --now nginx
