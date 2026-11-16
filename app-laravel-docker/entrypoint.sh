#!/bin/sh
# =============================================================================
# Entrypoint Laravel (container attendapp-app / PHP-FPM)
# Menjalankan hal-hal rutin sebelum PHP-FPM dijalankan:
#   1. Menyiapkan direktori storage & bootstrap/cache
#   2. Memperbaiki permission storage & bootstrap/cache (pengganti chmod manual)
#   3. composer install bila vendor/ belum ada
#   4. storage:link (symlink public/storage -> storage/app/public)
#   5. migrate (opsional, lewat RUN_MIGRATIONS=true)
#   6. cache config/route/view (opsional, lewat RUN_OPTIMIZE=true)
# =============================================================================
set -e

APP_DIR=/var/www/html

# Composer dijalankan sebagai root di dalam container -> izinkan tanpa prompt.
export COMPOSER_ALLOW_SUPERUSER=1
# Arahkan "home" Composer ke folder yang pasti bisa ditulis.
export COMPOSER_HOME="${COMPOSER_HOME:-/tmp/composer}"
mkdir -p "$COMPOSER_HOME"

# -----------------------------------------------------------------------------
# Git "dubious ownership".
# Folder aplikasi di-bind-mount dari VPS dan dimiliki user HOST (mis. user
# `ubuntu`/`deploy`), sedangkan proses di container berjalan sebagai ROOT.
# Git modern menolak bekerja pada repo milik UID lain:
#   fatal: detected dubious ownership in repository at '/var/www/html'
# Perintah di bawah membuat Git mempercayai folder tersebut. Aman karena
# container ini memang berisi satu aplikasi milik kita sendiri.
# -----------------------------------------------------------------------------
if command -v git >/dev/null 2>&1; then
    git config --global --add safe.directory "$APP_DIR" 2>/dev/null || true
fi

# User yang menjalankan worker PHP-FPM (harus sama dengan php/www.conf).
FPM_USER="${FPM_USER:-www-data}"
FPM_GROUP="${FPM_GROUP:-www-data}"

echo "==> Menyiapkan direktori storage..."
mkdir -p \
    "$APP_DIR/storage/logs" \
    "$APP_DIR/storage/framework/cache/data" \
    "$APP_DIR/storage/framework/sessions" \
    "$APP_DIR/storage/framework/views" \
    "$APP_DIR/bootstrap/cache" || true

# -----------------------------------------------------------------------------
# Perbaikan permission (pengganti "chmod manual" di Linux).
# Laravel WAJIB bisa MENULIS ke 2 folder berikut:
#   1) storage/         -> log, cache, session, file upload
#   2) bootstrap/cache/ -> cache config/route/view
# (public/ TIDAK perlu di-chmod karena hanya dibaca)
# -----------------------------------------------------------------------------
echo "==> Memperbaiki permission storage & bootstrap/cache (owner: $FPM_USER)..."
if [ "$(id -u)" = "0" ]; then
    # Container berjalan sebagai root -> samakan owner ke user PHP-FPM lalu beri akses
    chown -R "$FPM_USER:$FPM_GROUP" "$APP_DIR/storage" "$APP_DIR/bootstrap/cache" 2>/dev/null || true
    chmod -R 775 "$APP_DIR/storage" "$APP_DIR/bootstrap/cache" 2>/dev/null || true
else
    # Container berjalan sebagai non-root -> chmod sebisanya (butuh kita sebagai owner)
    chmod -R ug+rwX "$APP_DIR/storage" "$APP_DIR/bootstrap/cache" 2>/dev/null \
        || echo "!! Tidak bisa memperbaiki permission (bukan root). Jalankan di HOST: sudo chown -R $FPM_USER:$FPM_GROUP storage bootstrap/cache"
fi

# -----------------------------------------------------------------------------
# Pastikan APP_KEY tersedia. Laravel memakainya untuk mengenkripsi cookie &
# session, jadi tanpa ini setiap request gagal dengan
# "No application encryption key has been specified".
# Sebaiknya set permanen di app-laravel-docker/.env.docker.
# -----------------------------------------------------------------------------
if [ -z "${APP_KEY:-}" ]; then
    APP_KEY="base64:$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
    export APP_KEY
    echo "!! APP_KEY kosong -> dibuat SEMENTARA (session/cookie hangus tiap restart)."
    echo "!! Set APP_KEY permanen di app-laravel-docker/.env.docker"
fi

# -----------------------------------------------------------------------------
# Tunggu hingga PostgreSQL & Redis siap menerima koneksi.
# Container app dapat mulai sebelum database/redis siap (tergantung urutan
# compose up), jadi butuh mekanisme tunggu agar migrate tidak gagal.
#
# CATATAN REDIS: pengecekan TIDAK memakai trik bash `echo > /dev/tcp/host/port`
# karena image ini berbasis Alpine dan /bin/sh = BusyBox ash yang TIDAK
# mendukung /dev/tcp. Akibatnya pengecekan selalu gagal walau Redis hidup
# (gejala: "!! Redis belum siap setelah 30 detik"). Dipakai PHP CLI + fsockopen
# yang pasti tersedia di image ini.
# -----------------------------------------------------------------------------
echo "==> Menunggu PostgreSQL siap..."
for i in $(seq 1 60); do
    if pg_isready -h "${DB_HOST:-postgres-db}" -p "${DB_PORT:-5432}" -U "${DB_USERNAME:-postgres}" >/dev/null 2>&1; then
        echo "==> PostgreSQL siap."
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "!! PostgreSQL belum siap setelah 60 detik, lanjutkan tetap saja."
    fi
    sleep 1
done

echo "==> Menunggu Redis siap..."
for i in $(seq 1 30); do
    if php -r '
        $host = getenv("REDIS_HOST") ?: "redis-shared";
        $port = (int) (getenv("REDIS_PORT") ?: 6379);
        $pass = getenv("REDIS_PASSWORD");
        $fp = @fsockopen($host, $port, $errno, $errstr, 1.0);
        if (!$fp) { exit(1); }
        if ($pass && $pass !== "null") {
            // Redis dengan requirepass membalas "-NOAUTH" bila belum login;
            // itu artinya server HIDUP, jadi dianggap siap.
            fwrite($fp, "AUTH " . $pass . "\r\n");
            $line = (string) fgets($fp, 128);
            fclose($fp);
            exit(strpos($line, "+OK") === 0 ? 0 : 0);
        }
        fclose($fp);
        exit(0);
    ' >/dev/null 2>&1; then
        echo "==> Redis siap."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "!! Redis (${REDIS_HOST:-redis-shared}:${REDIS_PORT:-6379}) belum siap setelah 30 detik, lanjutkan tetap saja."
        echo "!! Pastikan compose redis-shared-docker sudah dijalankan lebih dulu."
    fi
    sleep 1
done

# Install dependency Composer bila vendor belum ada (mis. first deploy).
# Bila GAGAL, hentikan dengan pesan jelas: kalau dibiarkan, PHP-FPM tetap
# dijalankan tanpa autoloader dan semua request berakhir "500 / Class not
# found", sementara Docker me-restart container terus-menerus.
if [ ! -f "$APP_DIR/vendor/autoload.php" ]; then
    echo "==> vendor/ belum ada, menjalankan composer install..."
    if ! composer install --no-dev --optimize-autoloader --no-interaction --prefer-dist; then
        echo "!! composer install GAGAL. Container dihentikan agar error terlihat"
        echo "!! (tidak restart-loop). Periksa pesan Composer di atas, biasanya:"
        echo "!!   * composer.lock tidak kompatibel dengan PHP container"
        echo "!!   * koneksi internet container terputus"
        exit 1
    fi
fi

# Buat symlink storage bila belum ada
if [ ! -L "$APP_DIR/public/storage" ]; then
    echo "==> Membuat symlink storage..."
    php artisan storage:link || true
fi

# -----------------------------------------------------------------------------
# Perbaiki ulang permission SETELAH composer install.
# Composer dijalankan sebagai root sehingga file yang baru dibuat (termasuk
# bootstrap/cache/packages.php & services.php) dimiliki root. Worker PHP-FPM
# berjalan sebagai www-data dan harus bisa menimpanya saat config/route cache
# dibuat ulang.
# -----------------------------------------------------------------------------
if [ "$(id -u)" = "0" ]; then
    chown -R "$FPM_USER:$FPM_GROUP" "$APP_DIR/storage" "$APP_DIR/bootstrap/cache" 2>/dev/null || true
fi

# Migrasi database otomatis (opsional)
if [ "$RUN_MIGRATIONS" = "true" ]; then
    echo "==> Menjalankan migrasi database..."
    php artisan migrate --force || echo "!! migrate gagal (cek koneksi DB)"
fi

# Optimasi cache untuk produksi (opsional)
if [ "$RUN_OPTIMIZE" = "true" ]; then
    echo "==> Membuat cache konfigurasi/route/view..."
    php artisan config:cache || true
    php artisan route:cache  || true
    php artisan view:cache   || true
fi

echo "==> Entrypoint selesai. Menjalankan: $*"
exec "$@"