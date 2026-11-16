#!/usr/bin/env bash
# =============================================================================
# why-500.sh - Cari penyebab error 500 pada AttendApp (HANYA BACA)
#
# Jalankan di VPS:
#   cd ~/projects/docker-ecosystem
#   bash tools/why-500.sh
#
# Tidak mengubah apa pun. Output-nya bisa langsung ditempel untuk analisis.
# =============================================================================
set -u

APP_FPM="attendapp-app"
APP_NGINX="attendapp-nginx"
PROXY="reverse-proxy"
APP_PATH="${APP_PATH:-../attendapp}"
LOCAL_PORT="${LOCAL_PORT:-8101}"

hr() { printf '\n=============== %s ===============\n' "$1"; }
in_app() { docker exec "$APP_FPM" sh -c "$1" 2>&1; }

hr "0. Container yang berjalan"
docker ps --format '{{.Names}}\t{{.Status}}' | grep -E 'attendapp|redis-shared|postgres-db|reverse-proxy' || echo "(tidak ada)"

hr "1. *** LOG LARAVEL (paling penting) ***"
# 400 baris terakhir; bagian PENCARI MASALAH di bawah.
docker exec "$APP_FPM" sh -c 'test -f /var/www/html/storage/logs/laravel.log && tail -n 400 /var/www/html/storage/logs/laravel.log || echo "laravel.log BELUM ADA"' 2>&1

hr "1b. Ringkasan exception (20 terakhir)"
docker exec "$APP_FPM" sh -c 'grep -aE "^\[[0-9]{4}-" /var/www/html/storage/logs/laravel.log 2>/dev/null | tail -n 20' 2>&1 || true

hr "2. APP_KEY: bandingkan .env aplikasi vs .env.docker container"
# Nilai EFEKTIF yang dilihat Laravel (dari environment container).
docker exec "$APP_FPM" sh -c 'echo "efektif APP_KEY   : ${APP_KEY:-<KOSONG>}"; echo "efektif APP_ENV   : ${APP_ENV:-<KOSONG>}"; echo "efektif APP_DEBUG : ${APP_DEBUG:-<KOSONG>}"' 2>&1
if docker exec "$APP_FPM" sh -c 'test -f /var/www/html/.env' 2>/dev/null; then
    docker exec "$APP_FPM" sh -c 'echo "di .env aplikasi: $(grep -a "^APP_KEY=" /var/www/html/.env)"' 2>&1
fi

hr "3. Redis dari container app (host + auth + DB + ping)"
docker exec "$APP_FPM" sh -c 'php -r "
\$h = getenv(\"REDIS_HOST\") ?: \"redis-shared\";
\$p = (int) (getenv(\"REDIS_PORT\") ?: 6379);
\$a = getenv(\"REDIS_PASSWORD\");
echo \"  host=\$h port=\$p pass=\" . (\$a && \$a !== \"null\" ? \"ada\" : \"kosong\") . PHP_EOL;
try {
    \$r = new Redis();
    \$r->connect(\$h, \$p, 2.0);
    if (\$a && \$a !== \"null\") { \$r->auth(\$a); }
    echo \"  PING: \" . \$r->ping() . PHP_EOL;
    echo \"  keys di DB \" . (\$r->select((int)(getenv(\"REDIS_DB\") ?: 0)) ? \"ok\" : \"gagal\") . PHP_EOL;
    \$info = \$r->info();
    echo \"  redis_version: \" . (\$info[\"redis_version\"] ?? \"?\") . PHP_EOL;
} catch (Throwable \$e) {
    echo \"  GAGAL: \" . \$e->getMessage() . PHP_EOL;
}
"' 2>&1

hr "4. Redis DI DALAM container redis-shared (server-side)"
docker exec redis-shared sh -c 'redis-cli -a "$REDIS_PASSWORD" ping' 2>&1 | grep -v Warning || echo "(tidak bisa akses container redis-shared)"

hr "5. Laravel: config efektif yang dilihat aplikasi"
docker exec "$APP_FPM" sh -c 'cd /var/www/html && php artisan tinker --execute="echo \"app.key     : \" . (config(\"app.key\") ? substr(config(\"app.key\"),0,12) . \"...\" : \"<KOSONG>\") . PHP_EOL; echo \"app.env     : \" . config(\"app.env\") . PHP_EOL; echo \"cache.default: \" . config(\"cache.default\") . PHP_EOL; echo \"session.driver: \" . config(\"session.driver\") . PHP_EOL; echo \"db.default  : \" . config(\"database.default\") . PHP_EOL; echo \"redis.host  : \" . config(\"database.redis.default.host\") . PHP_EOL; echo \"redis.db    : \" . config(\"database.redis.default.database\") . PHP_EOL;" 2>&1' 2>&1 || echo "(tinker gagal)"

hr "6. Tes boot Laravel + koneksi DB/Redis (tanpa HTTP)"
docker exec "$APP_FPM" sh -c 'cd /var/www/html && php artisan tinker --execute="
try { \DB::connection()->getPdo(); echo \"DB  : OK\" . PHP_EOL; } catch (Throwable \$e) { echo \"DB  : GAGAL -> \" . \$e->getMessage() . PHP_EOL; }
try { \Cache::put(\"healthcheck\", 1, 60); echo \"CACHE: OK (\" . var_export(\Cache::get(\"healthcheck\"), true) . \")\" . PHP_EOL; } catch (Throwable \$e) { echo \"CACHE: GAGAL -> \" . \$e->getMessage() . PHP_EOL; }
try { \Illuminate\Support\Facades\Redis::connection()->ping(); echo \"REDIS: OK\" . PHP_EOL; } catch (Throwable \$e) { echo \"REDIS: GAGAL -> \" . \$e->getMessage() . PHP_EOL; }
try { \Session::put(\"hc\", 1); echo \"SESSION: OK\" . PHP_EOL; } catch (Throwable \$e) { echo \"SESSION: GAGAL -> \" . \$e->getMessage() . PHP_EOL; }
"' 2>&1

hr "7. config:cache — apakah ada APP_KEY/cache basi?"
docker exec "$APP_FPM" sh -c 'ls -la /var/www/html/bootstrap/cache/ 2>&1' 2>&1
docker exec "$APP_FPM" sh -c 'grep -ao "APP_KEY[^,]*" /var/www/html/bootstrap/cache/config.php 2>/dev/null | head -3' 2>&1 || true

hr "8. Permission storage & bootstrap/cache"
docker exec "$APP_FPM" sh -c 'ls -ld /var/www/html/storage /var/www/html/storage/logs /var/www/html/bootstrap/cache 2>&1; echo "--- isi log dir ---"; ls -la /var/www/html/storage/logs 2>&1' 2>&1

hr "9. HTTP test berlapis"
docker exec "$APP_NGINX" wget -qS -O /dev/null "http://127.0.0.1/login" 2>&1 | head -8
curl -s -o /dev/null -w "host :%{http_code}\n" "http://127.0.0.1:$LOCAL_PORT/login" 2>&1 || true

hr "SELESAI"
echo "Kirim seluruh output, terutama bagian 1, 2, 3, dan 6."
