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

hr "7. Deteksi CACHE BASI (bootstrap/cache/config.php lama vs environment)"
echo "--- isi bootstrap/cache ---"
docker exec "$APP_FPM" sh -c 'ls -la /var/www/html/bootstrap/cache/ 2>&1' 2>&1
# config.php = nilai yang BENAR-BENAR dipakai Laravel. PENTING: selama file ini
# ada, Laravel MEMAKAI isinya dan MELEWATI .env sepenuhnya
# (LoadConfiguration: if (file_exists($cached)) { $items = require $cached; ... }),
# sehingga perubahan .env.docker seolah tidak berefek.
docker exec "$APP_FPM" php -r '
$f = "/var/www/html/bootstrap/cache/config.php";
$keyOk = function ($k) {
    $k = (string) $k;
    if ($k === "") { return false; }
    if (strpos($k, "base64:") === 0) { $k = (string) base64_decode(substr($k, 7), true); }
    return strlen($k) === 32;
};
$envKey  = (string) getenv("APP_KEY");
$envHost = (string) (getenv("REDIS_HOST") ?: "(kosong)");
$envPass = (string) getenv("REDIS_PASSWORD");
$envPass = ($envPass !== "" && $envPass !== "null") ? "ADA" : "KOSONG";
echo "[env]   APP_KEY valid  : " . ($keyOk($envKey) ? "YA" : "TIDAK -> SEMUA request 500") . PHP_EOL;
echo "[env]   APP_KEY prefix : " . ($envKey === "" ? "(kosong)" : substr($envKey, 0, 14) . "...") . PHP_EOL;
echo "[env]   redis.host     : " . $envHost . PHP_EOL;
echo "[env]   redis.password : " . $envPass . PHP_EOL;
echo "[env]   RUN_OPTIMIZE   : " . ((string) (getenv("RUN_OPTIMIZE") ?: "(kosong)")) . PHP_EOL;
echo "[env]   RUN_MIGRATIONS : " . ((string) (getenv("RUN_MIGRATIONS") ?: "(kosong)")) . PHP_EOL;
if (!is_file($f)) {
    echo PHP_EOL . ">>> config.php TIDAK ADA -> tidak ada cache basi." . PHP_EOL;
    echo "    (Normal bila RUN_OPTIMIZE=false; Laravel membaca .env langsung.)" . PHP_EOL;
    exit(0);
}
$c     = require $f;
$cKey  = (string) ($c["app"]["key"] ?? "");
$cHost = (string) ($c["database"]["redis"]["default"]["host"] ?? "");
$cPass = (string) ($c["database"]["redis"]["default"]["password"] ?? "");
$cDb   = (string) ($c["database"]["redis"]["default"]["database"] ?? "");
echo PHP_EOL;
echo "[cache] umur file      : " . date("Y-m-d H:i:s", (int) filemtime($f)) . PHP_EOL;
echo "[cache] APP_KEY        : " . ($cKey === "" ? "(kosong)" : substr($cKey, 0, 14) . "...") . PHP_EOL;
echo "[cache] redis.host     : " . $cHost . PHP_EOL;
echo "[cache] redis.password : " . ($cPass !== "" ? "ADA" : "KOSONG") . PHP_EOL;
echo "[cache] redis.db       : " . $cDb . PHP_EOL;
echo "[cache] cache.default  : " . (string) ($c["cache"]["default"] ?? "?") . PHP_EOL;
echo "[cache] session.driver : " . (string) ($c["session"]["driver"] ?? "?") . PHP_EOL;
echo "[cache] db.default     : " . (string) ($c["database"]["default"] ?? "?") . PHP_EOL;
$stale = [];
if ($cHost !== $envHost) { $stale[] = "redis.host cache=" . $cHost . " != env=" . $envHost; }
if ($cPass === "" && $envPass === "ADA") { $stale[] = "redis.password cache KOSONG padahal env ADA -> NOAUTH Authentication required"; }
if ($cKey !== $envKey) { $stale[] = "APP_KEY cache != env -> session/cookie didekripsi dengan kunci lama"; }
if (!$keyOk($envKey)) { $stale[] = "APP_KEY env tidak valid (butuh base64: 32 byte) -> RuntimeException correct key lengths"; }
$runOpt = (string) (getenv("RUN_OPTIMIZE") ?: "");
if ($runOpt !== "true") {
    $stale[] = "RUN_OPTIMIZE=" . ($runOpt === "" ? "(kosong)" : $runOpt) . " -> cache TIDAK akan pernah dibangun ulang (selama config.php ada, .env diabaikan)";
}
echo PHP_EOL;
if ($stale) {
    echo ">>> DIAGNOSA: CACHE BASI / APP_KEY SALAH." . PHP_EOL;
    foreach ($stale as $s) { echo "    - " . $s . PHP_EOL; }
    echo "    Perbaikan:" . PHP_EOL;
    echo "      1) samakan REDIS_HOST/REDIS_PASSWORD/APP_KEY di app-laravel-docker/.env.docker" . PHP_EOL;
    echo "         dengan redis-shared-docker/.env.docker lalu rebuild:" . PHP_EOL;
    echo "           docker compose up -d --build --force-recreate app" . PHP_EOL;
    echo "         Entrypoint terbaru otomatis menjalankan optimize:clear SEBELUM config:cache," . PHP_EOL;
    echo "         jadi nilai basi tidak lagi dipakai ulang." . PHP_EOL;
    echo "      2) perbaikan cepat tanpa rebuild:" . PHP_EOL;
    echo "           docker exec attendapp-app sh -c \"cd /var/www/html && rm -f bootstrap/cache/config.php bootstrap/cache/routes-v7.php\"" . PHP_EOL;
    echo "           docker compose restart app" . PHP_EOL;
} else {
    echo ">>> TIDAK ada cache basi: nilai di config.php == environment. Masalah 500 ada di tempat lain." . PHP_EOL;
}
' 2>&1

hr "8. Permission storage & bootstrap/cache"
docker exec "$APP_FPM" sh -c 'ls -ld /var/www/html/storage /var/www/html/storage/logs /var/www/html/bootstrap/cache 2>&1; echo "--- isi log dir ---"; ls -la /var/www/html/storage/logs 2>&1' 2>&1

hr "9. HTTP test berlapis"
docker exec "$APP_NGINX" wget -qS -O /dev/null "http://127.0.0.1/login" 2>&1 | head -8
curl -s -o /dev/null -w "host :%{http_code}\n" "http://127.0.0.1:$LOCAL_PORT/login" 2>&1 || true

hr "10. PHP-FPM: apakah environment container sampai ke worker HTTP?"
# Default PHP-FPM `clear_env = yes` membuang SEMUA env container sebelum worker
# dijalankan. Akibatnya `docker exec app php artisan tinker` (CLI) melihat
# .env.docker, tetapi permintaan HTTP hanya melihat attendapp/.env (nilai lokal
# 127.0.0.1) -> halaman 500 walau CLI melaporkan DB/Redis benar.
clear_env_cfg=$(docker exec "$APP_FPM" sh -c 'grep -h "^clear_env" /usr/local/etc/php-fpm.d/*.conf /usr/local/etc/php-fpm.conf 2>/dev/null | tail -n 1' 2>/dev/null)
case "$clear_env_cfg" in
    *no) echo "  OK: ($clear_env_cfg) -> environment container diteruskan ke worker HTTP." ;;
    "")  echo "  !! clear_env TIDAK diset -> default PHP-FPM = yes -> env container DIBUANG untuk HTTP." ;;
    *)   echo "  !! $clear_env_cfg -> env container DIBUANG untuk HTTP." ;;
esac
echo "  Perbaikan: pastikan app-laravel-docker/php/www.conf memuat 'clear_env = no',"
echo "  lalu: docker compose up -d --build --force-recreate app  (www.conf di-COPY ke image)."
if [ -f "$APP_PATH/.env" ]; then
    echo "--- nilai berisiko di attendapp/.env (hanya terpakai bila env container tidak sampai) ---"
    grep -nE '^(DB_HOST|REDIS_HOST|REDIS_PASSWORD|CACHE_DRIVER|SESSION_DRIVER|APP_ENV)=' "$APP_PATH/.env" 2>&1 || true
fi

hr "SELESAI"
echo "Kirim seluruh output, terutama bagian 1, 2, 3, 6, 7, dan 10."
