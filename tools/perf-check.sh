#!/usr/bin/env bash
# =============================================================================
# perf-check.sh - Cek "kenapa lambat" dengan ANGKA, bukan tebakan.
#
# HANYA BACA: tidak mengubah konfigurasi, tidak menghapus cache, tidak
# me-restart container.
#
# Jalankan di VPS dari root repo docker-ecosystem:
#   cd ~/projects/docker-ecosystem
#   bash tools/perf-check.sh
#
# Yang diukur:
#   1. Memori host & swap      -> swap terpakai = penyebab lambat paling umum
#   2. Beban container         -> container mana yang menghabiskan RAM/CPU
#   3. Kompresi gzip           -> aset dikirim terkompresi atau mentah?
#   4. TTFB dari DALAM VPS     -> memisahkan "aplikasi lambat" vs "jaringan"
#   5. Cache produksi Laravel  -> config/route/view cache benar-benar ada?
#   6. OPcache                 -> kode PHP di-parse ulang tiap request?
#   7. Setelan PostgreSQL      -> sesuai RAM VPS?
#   8. Redis                   -> memori & kebijakan eviction
#
# Cara membaca hasilnya:
#   - TTFB kecil (<300 ms) tapi dari laptop terasa lambat -> masalah JARINGAN/
#     lokasi datacenter/aset, BUKAN PHP. Solusi: CDN, HTTP/2, gzip, atau
#     pindah region.
#   - TTFB besar (>800 ms) -> masalah APLIKASI/DB/server (cek poin 5-7).
#   - Swap terpakai > 0 dan terus naik -> RAM kurang (lihat poin 1 & 7).
# =============================================================================
set -u

APP_PATH="${APP_PATH:-../attendapp}"
APP_FPM="attendapp-app"
PROXY="reverse-proxy"
DB="postgres-db"
REDIS="redis-shared"
LOCAL_PORT="${LOCAL_PORT:-8101}"

hr() { printf '\n=============== %s ===============\n' "$1"; }

hr "1. Memori & swap host (swap terpakai = red flag)"
free -h 2>/dev/null || echo "(free tidak tersedia)"
echo "--- 5 sampel vmstat (kolom si/so harus 0 = tidak swap) ---"
vmstat 1 5 2>/dev/null || echo "(vmstat tidak tersedia)"
echo "--- load average ---"
uptime 2>/dev/null || true

hr "2. Pemakaian resource per container"
docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}' 2>/dev/null \
    | head -12 || echo "(docker stats gagal)"

hr "3. Kompresi gzip: apakah aset dikirim terkompresi?"
ASSET="/form/css/style.css"
for target in "http://127.0.0.1:$LOCAL_PORT" "http://127.0.0.1"; do
    echo "--- $target$ASSET ---"
    # -I: hanya header. Yang dicari: Content-Encoding: gzip
    curl -s -o /dev/null -D - -H 'Accept-Encoding: gzip, deflate' "$target$ASSET" 2>/dev/null \
        | grep -iE '^(HTTP/|content-encoding|content-length|cache-control|vary)' \
        || echo "  (tidak ada respons / aset tidak ditemukan)"
    SENT=$(curl -s -o /dev/null -w '%{size_download}' -H 'Accept-Encoding: gzip' "$target$ASSET" 2>/dev/null || echo 0)
    echo "  byte terkirim (dengan Accept-Encoding gzip): $SENT"
done
echo
echo "Jika TIDAK ada 'Content-Encoding: gzip' -> gzip belum aktif."
echo "Jika byte terkirim mendekati ukuran file asli -> tidak terkompresi."
ls -l "$APP_PATH/public$ASSET" 2>/dev/null || true

hr "4. TTFB dari DALAM VPS (tanpa pengaruh jaringan internet)"
for i in 1 2 3; do
    curl -s -o /dev/null \
        -w "  #$i via :$LOCAL_PORT  ttfb=%{time_starttransfer}s  total=%{time_total}s  code=%{http_code}\n" \
        "http://127.0.0.1:$LOCAL_PORT/login" 2>/dev/null || echo "  #$i gagal"
done
for i in 1 2 3; do
    curl -s -o /dev/null \
        -w "  #$i via :80          ttfb=%{time_starttransfer}s  total=%{time_total}s  code=%{http_code}\n" \
        -H "Host: app.attendapp.local" "http://127.0.0.1/login" 2>/dev/null || echo "  #$i gagal"
done
hr "5. Cache produksi Laravel (config/route/view)"
docker exec "$APP_FPM" sh -c '
    cd /var/www/html || exit 0
    echo "-- bootstrap/cache (harus ada config.php & routes-v7.php):"
    ls -la bootstrap/cache/ 2>/dev/null
    echo "-- jumlah view terkompilasi (harus > 0 setelah view:cache):"
    ls storage/framework/views 2>/dev/null | wc -l
    echo "-- nilai env yang BENAR-BENAR dipakai:"
    php -r "
        \$app = require \"bootstrap/app.php\";
        \$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
        printf(\"   app_env=%s app_debug=%s cache=%s session=%s queue=%s\\n\",
            config(\"app.env\"), var_export(config(\"app.debug\"), true),
            config(\"cache.default\"), config(\"session.driver\"), config(\"queue.default\"));
    " 2>&1 | tail -3
' 2>&1 || echo "(exec gagal: container $APP_FPM tidak berjalan)"

hr "6. OPcache (kode PHP di-parse ulang tiap request?)"
docker exec "$APP_FPM" php -r '
    $s = @opcache_get_status(false);
    if (!is_array($s)) { echo "  OPcache TIDAK aktif\n"; exit; }
    printf("  enabled=%s  cached_scripts=%d  hits=%d  misses=%d  used_mem=%.1f MB  free_mem=%.1f MB\n",
        var_export($s["opcache_enabled"], true),
        $s["opcache_statistics"]["num_cached_scripts"],
        $s["opcache_statistics"]["hits"],
        $s["opcache_statistics"]["misses"],
        $s["memory_usage"]["used_memory"]/1048576,
        $s["memory_usage"]["free_memory"]/1048576);
    echo "  validate_timestamps=" . ini_get("opcache.validate_timestamps")
       . " (0 = tercepat, khas produksi)\n";
' 2>&1 || echo "(exec gagal)"

hr "7. Setelan PostgreSQL vs RAM VPS"
docker exec "$DB" psql -U postgres -d attendapp -At -c \
  "select 'shared_buffers=' || current_setting('shared_buffers')
       || ' work_mem=' || current_setting('work_mem')
       || ' max_connections=' || current_setting('max_connections')
       || ' effective_cache_size=' || current_setting('effective_cache_size');" 2>&1 || echo "(exec gagal)"
echo "--- query paling lambat (butuh pg_stat_statements; abaikan bila error) ---"
docker exec "$DB" psql -U postgres -d attendapp -At -c \
  "select round(total_exec_time::numeric,1) || ' ms | calls=' || calls || ' | ' || left(regexp_replace(query, '\\s+', ' ', 'g'), 90)
     from pg_stat_statements order by total_exec_time desc limit 5;" 2>&1 | head -6 || true

hr "8. Redis (memori & eviction)"
docker exec "$REDIS" sh -c 'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning info memory 2>/dev/null | grep -E "used_memory_human|maxmemory_human|maxmemory_policy"; redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ping' 2>&1 \
    || echo "(exec gagal: container $REDIS tidak berjalan)"

hr "9. Ringkasan cepat"
echo "  RAM   : $(free -m 2>/dev/null | awk '/Mem:/{print $3" MB terpakai dari "$2" MB"}')"
echo "  swap  : $(free -m 2>/dev/null | awk '/Swap:/{print $3" MB terpakai dari "$2" MB"}')"
echo
echo "Arti hasil:"
echo "  - gzip TIDAK aktif              -> aktifkan (sudah disiapkan di nginx/default.conf)"
echo "  - TTFB dari dalam VPS > 800 ms  -> masalah aplikasi/DB, bukan jaringan"
echo "  - TTFB dalam VPS kecil          -> masalah jaringan/aset: pakai CDN + HTTP/2"
echo "  - bootstrap/cache kosong        -> RUN_OPTIMIZE=true belum efektif"
echo "  - swap > 0                      -> turunkan POSTGRES_TUNING (db-postgres-docker/.env.docker)"

echo
echo "Pembanding: dari LAPTOP Anda (bukan VPS) jalankan:"
echo "  curl -o /dev/null -s -w 'connect=%{time_connect} tls=%{time_appconnect} ttfb=%{time_starttransfer} total=%{time_total}\\n' http://IP_VPS:$LOCAL_PORT/login"
