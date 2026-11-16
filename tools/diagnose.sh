#!/usr/bin/env bash
# =============================================================================
# diagnose.sh - Diagnosa cepat stack AttendApp (HANYA BACA, tidak mengubah apa pun)
#
# Jalankan di VPS dari root repo docker-ecosystem:
#   cd ~/projects/docker-ecosystem
#   bash tools/diagnose.sh
#
# Lalu tempelkan seluruh output-nya untuk analisis.
# =============================================================================
set -u

APP_PATH="${APP_PATH:-../attendapp}"
APP_COMPOSE="app-laravel-docker/docker-compose.yml"
PROXY_COMPOSE="reverse-proxy-docker/docker-compose.yml"
PROXY_CONTAINER="reverse-proxy"
APP_NGINX="attendapp-nginx"
APP_FPM="attendapp-app"
LOCAL_PORT="${LOCAL_PORT:-8101}"

hr() { printf '\n=============== %s ===============\n' "$1"; }

hr "0. Waktu & versi Docker"
date -u
docker --version
docker compose version

hr "1. Status container (semua project yang menyentuh stack ini)"
docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E 'attendapp|reverse-proxy|postgres|redis|app' || echo "(tidak ada)"

hr "2. Port host yang mendengarkan (80, 443, 5432, 8101)"
(ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null) | grep -E ':80\b|:443\b|:5432\b|:8101\b' || echo "(tidak ada yang listen di port tsb)"

hr "3. Anggota network shared-network"
docker network inspect shared-network --format '{{range .Containers}}{{.Name}}  {{.IPv4Address}}{{"\n"}}{{end}}' 2>/dev/null || echo "network shared-network TIDAK ADA"

hr "4. Compose config yang BENAR-BENAR dipakai reverse proxy"
docker compose -f "$PROXY_COMPOSE" config 2>&1 | sed -n '1,40p'

hr "5. Config nginx yang DIMUAT reverse proxy (aktif saat ini)"
docker exec "$PROXY_CONTAINER" nginx -T 2>/dev/null | grep -nE 'listen|server_name|proxy_pass|resolver|client_max_body_size' || echo "(gagal: container tidak berjalan / exec gagal)"

hr "6. Tes nginx -t di kedua container"
docker exec "$PROXY_CONTAINER" nginx -t 2>&1 || true
docker exec "$APP_NGINX" nginx -t 2>&1 || true

hr "7. DNS: apa attendapp-nginx bisa di-resolve DARI reverse proxy?"
docker exec "$PROXY_CONTAINER" getent hosts "$APP_NGINX" 2>&1 || echo "GAGAL resolve $APP_NGINX"
docker exec "$PROXY_CONTAINER" getent hosts "$APP_FPM" 2>&1 || echo "GAGAL resolve $APP_FPM"
docker exec "$PROXY_CONTAINER" getent hosts redis-shared 2>&1 || echo "GAGAL resolve redis-shared"

hr "8. HTTP test DARI reverse proxy -> nginx aplikasi"
docker exec "$PROXY_CONTAINER" wget -qS -O /dev/null "http://$APP_NGINX/" 2>&1 | head -12 || echo "request gagal"

hr "9. HTTP test DARI nginx aplikasi -> PHP-FPM (via localhost)"
docker exec "$APP_NGINX" wget -qS -O /dev/null "http://127.0.0.1/login" 2>&1 | head -12 || echo "request gagal"

hr "10. HTTP test DARI HOST ke port $LOCAL_PORT dan port 80"
curl -s -o /dev/null -w "host -> :$LOCAL_PORT  status=%{http_code}  (redirect: %{redirect_url})\n" "http://127.0.0.1:$LOCAL_PORT/" 2>&1 || echo "gagal"
curl -s -o /dev/null -w "host -> :80         status=%{http_code}  (redirect: %{redirect_url})\n" "http://127.0.0.1/" 2>&1 || echo "gagal"

hr "11. PHP-FPM di container app"
docker exec "$APP_FPM" sh -c 'php-fpm -t 2>&1 | tail -3; grep -n "^listen" /usr/local/etc/php-fpm.d/www.conf' 2>&1 || echo "(exec gagal)"
docker exec "$APP_FPM" sh -c 'ps aux | grep -c "[p]hp-fpm"' 2>&1 || true

hr "12. Laravel: status route cache & duplikasi nama route"
if [ -d "$APP_PATH" ]; then
  ( cd "$APP_PATH" || exit 0
    echo "-- git:"
    git log --oneline -3 2>&1 || echo "(bukan repo git)"
    git status --short 2>&1 | head -10
    echo "-- grep name('dashboard'):"
    grep -n "name('dashboard')" routes/web.php 2>&1 || echo "(tidak ada)"
    echo "-- bootstrap/cache:"
    ls -la bootstrap/cache/ 2>&1
  )
else
  echo "APP_PATH=$APP_PATH tidak ditemukan (set APP_PATH=... bila beda)"
fi

hr "13. Laravel: coba route:cache (aman, hanya menulis bootstrap/cache)"
docker exec "$APP_FPM" sh -c 'cd /var/www/html && php artisan route:cache 2>&1 | tail -5' 2>&1 || true

hr "14. Log terakhir: app (60 baris)"
docker compose -f "$APP_COMPOSE" logs --tail=60 app 2>&1

hr "15. Log terakhir: nginx aplikasi (40 baris)"
docker compose -f "$APP_COMPOSE" logs --tail=40 laravel-nginx 2>&1

hr "16. Log terakhir: reverse proxy (40 baris)"
docker compose -f "$PROXY_COMPOSE" logs --tail=40 reverse-proxy 2>&1

hr "SELESAI"
echo "Tempelkan seluruh output di atas."
