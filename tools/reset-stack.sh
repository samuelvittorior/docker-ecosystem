#!/usr/bin/env bash
# =============================================================================
# reset-stack.sh - Bersihkan sisa container lama AttendApp lalu jalankan ulang
#
# Jalankan di VPS dari root repo docker-ecosystem:
#   cd ~/projects/docker-ecosystem
#   bash tools/reset-stack.sh
#
# Yang dilakukan:
#   1. Hentikan & hapus container sisa dari nama lama pada penamaan stack ini
#      (nama service pernah berganti-ganti: laravel-app, laravel-nginx, dst).
#   2. Recreate reverse-proxy supaya config nginx BARU benar-benar dimuat.
#   3. Build & jalankan stack aplikasi.
#   4. Cetak hasil pemeriksaan DNS + HTTP.
#
# AMAN untuk data: volume `postgres-data` dan `redis-data` TIDAK dihapus.
# (Menghapus volume database hanya dilakukan pada bagian opsional di bawah.)
# =============================================================================
set -u

PROXY_CONTAINER="reverse-proxy"
APP_FPM="attendapp-app"
APP_NGINX="attendapp-nginx"
LOCAL_PORT="${LOCAL_PORT:-8101}"

hr() { printf '\n=============== %s ===============\n' "$1"; }

hr "1. Bersihkan container lama & sisa project sebelumnya"
# Hentikan dulu project compose ini (jika masih terdaftar), supaya container
# yang dikelolanya dilepas dengan rapi.
( cd app-laravel-docker && docker compose down --remove-orphans >/dev/null 2>&1 ) || true

# Nama-nama yang mungkin tersisa dari penamaan versi sebelumnya.
# `container_name` bersifat UNIK di seluruh Docker host: bila container bernama
# sama masih ada (mis. dibuat compose project lama / folder lain), maka
# `docker compose up` GAGAL dengan:
#   Error response from daemon: Conflict. The container name "/attendapp-nginx"
#   is already in use by container "abc123..."
# Akibatnya service nginx tidak pernah jalan -> DNS "attendapp-nginx" tidak ada
# -> reverse proxy balas 502 "could not be resolved".
STALE="attendapp-app attendapp-nginx attendapp-redis redis-shared laravel-app laravel-nginx laravel-redis laravel-test-app laravel-test-nginx laravel-test-redis app-laravel-docker-redis-1"
for c in $STALE; do
    if docker ps -a --format '{{.Names}}' | grep -qx "$c"; then
        echo "  - hapus container: $c"
        docker rm -f "$c" >/dev/null 2>&1 || echo "    (gagal menghapus, lanjut)"
    fi
done
echo "  selesai."

hr "2. Recreate reverse proxy (memuat nginx/default.conf terbaru)"
( cd reverse-proxy-docker && docker compose up -d --force-recreate ) || exit 1
docker exec "$PROXY_CONTAINER" nginx -t 2>&1 || true

hr "3. Build & jalankan stack aplikasi (app + nginx)"
# Redis TIDAK lagi di compose ini -- jalankan redis-shared-docker lebih dulu.
( cd redis-shared-docker && docker compose up -d ) || echo "  !! redis-shared-docker gagal dijalankan"
( cd app-laravel-docker && docker compose up -d --build --remove-orphans app laravel-nginx ) || exit 1

hr "4. Tunggu container aplikasi siap (maks 90 detik)"
for i in $(seq 1 90); do
    state=$(docker inspect -f '{{.State.Status}}' "$APP_NGINX" 2>/dev/null || echo "missing")
    if [ "$state" = "running" ]; then
        echo "  $APP_NGINX: running (setelah ${i}s)"
        break
    fi
    if [ "$i" -eq 90 ]; then
        echo "  !! $APP_NGINX belum running (state=$state)"
        echo "  !! Cek penyebabnya:"
        echo "     docker compose -f app-laravel-docker/docker-compose.yml logs --tail=40 laravel-nginx"
        echo "     docker ps -a --format '{{.Names}}\t{{.Status}}' | grep -E 'attendapp|laravel'"
    fi
    sleep 1
done

hr "4b. Status ketiga container kunci"
docker ps -a --format '{{.Names}}\t{{.Status}}' | grep -E 'attendapp|reverse-proxy|postgres' || echo "  (tidak ada)"

hr "5. Anggota shared-network (harus ada attendapp-nginx & redis-shared)"
docker network inspect shared-network --format '{{range .Containers}}{{.Name}}  {{.IPv4Address}}{{"\n"}}{{end}}' 2>/dev/null \
  || echo "  !! network shared-network tidak ada"

hr "6. Tes DNS dari dalam reverse-proxy"
docker exec "$PROXY_CONTAINER" getent hosts "$APP_NGINX" && echo "  OK: $APP_NGINX ter-resolve" \
  || echo "  !! GAGAL: $APP_NGINX tidak ter-resolve -> cek langkah 1 & 3"
docker exec "$PROXY_CONTAINER" getent hosts redis-shared >/dev/null 2>&1 \
  && echo "  OK: redis-shared ada di shared-network" \
  || echo "  !! redis-shared belum terdaftar -> jangan lupa 'cd redis-shared-docker && docker compose up -d'"

hr "7. Tes HTTP berlapis"
docker exec "$PROXY_CONTAINER" wget -qS -O /dev/null "http://$APP_NGINX/" 2>&1 | head -6
curl -s -o /dev/null -w "host -> :%{http_code}\n" "http://127.0.0.1:$LOCAL_PORT/" 2>&1 || true
curl -s -o /dev/null -w "  redirect: %{redirect_url}\n" "http://127.0.0.1:$LOCAL_PORT/" 2>&1 || true

hr "7b. Redis: cek auth dari container app"
docker exec "$APP_FPM" sh -c 'php -r "
\$h = getenv(\"REDIS_HOST\") ?: \"redis-shared\";
\$p = (int) (getenv(\"REDIS_PORT\") ?: 6379);
\$a = getenv(\"REDIS_PASSWORD\");
\$r = new Redis();
try { \$r->connect(\$h, \$p, 2.0); if (\$a && \$a !== \"null\") { \$r->auth(\$a); } echo \"  OK: REDIS_HOST=\$h:\$p auth=\" . (\$a && \$a!==\"null\" ? \"ya\" : \"tidak\") . \" ping=\" . \$r->ping() . PHP_EOL; }
catch (Throwable \$e) { echo \"  !! GAGAL: \" . \$e->getMessage() . PHP_EOL; }
"' 2>&1

hr "8. Log singkat"
docker compose -f reverse-proxy-docker/docker-compose.yml logs --tail=15 "$PROXY_CONTAINER" 2>&1

hr "8b. Self-check entrypoint (config efektif + Redis/DB)"
# Entrypoint menuliskan nilai config yang BENAR-BENAR dipakai Laravel beserta
# status Redis & Database. Kalau HTTP masih 500, baris-baris ini biasanya
# sudah menunjuk penyebabnya (mis. NOAUTH / APP_KEY tidak valid).
docker compose -f app-laravel-docker/docker-compose.yml logs app 2>&1 \
    | grep -aE 'config efektif|Redis:|Redis \(via|Database:|GAGAL|AUTH DITOLAK|bootstrap GAGAL|gagal' | tail -n 15 \
    || echo "  (belum ada baris self-check: pastikan RUN_OPTIMIZE=true dan image sudah di-build ulang)"

hr "SELESAI"
echo "Buka: http://<IP_VPS>:$LOCAL_PORT/"
echo
echo "--- OPSIONAL: reset total (HAPUS DATA database & redis) ---"
echo "Jalankan hanya bila memang ingin mulai dari nol:"
echo "  cd app-laravel-docker && docker compose down"
echo "  docker volume ls | grep -E 'postgres-data|redis-data'"
echo "  docker volume rm \$(docker volume ls -q | grep -E 'postgres-data|redis-data')"
