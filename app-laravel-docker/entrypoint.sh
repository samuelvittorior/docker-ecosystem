#!/bin/sh
# =============================================================================
# Entrypoint Laravel (container laravel-app / PHP-FPM)
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

# Install dependency Composer bila vendor belum ada (mis. first deploy)
if [ ! -f "$APP_DIR/vendor/autoload.php" ]; then
    echo "==> vendor/ belum ada, menjalankan composer install..."
    composer install --no-dev --optimize-autoloader --no-interaction --prefer-dist
fi

# Buat symlink storage bila belum ada
if [ ! -L "$APP_DIR/public/storage" ]; then
    echo "==> Membuat symlink storage..."
    php artisan storage:link || true
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