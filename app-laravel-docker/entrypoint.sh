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

# Container berjalan sebagai non-root, jadi arahkan "home" Composer ke folder
# yang pasti bisa ditulis agar "composer install" tidak gagal.
export COMPOSER_HOME="${COMPOSER_HOME:-/tmp/composer}"
mkdir -p "$COMPOSER_HOME"

echo "==> Menyiapkan direktori storage..."
mkdir -p \
    "$APP_DIR/storage/logs" \
    "$APP_DIR/storage/framework/cache/data" \
    "$APP_DIR/storage/framework/sessions" \
    "$APP_DIR/storage/framework/views" \
    "$APP_DIR/bootstrap/cache"

# -----------------------------------------------------------------------------
# Perbaikan permission (pengganti "chmod manual" di Linux).
# Laravel WAJIB bisa MENULIS ke 2 folder berikut:
#   1) storage/         -> log, cache, session, file upload
#   2) bootstrap/cache/ -> cache config/route/view
# (public/ TIDAK perlu di-chmod karena hanya dibaca)
# -----------------------------------------------------------------------------
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"

echo "==> Memperbaiki permission storage & bootstrap/cache..."
if [ "$(id -u)" = "0" ]; then
    # Container berjalan sebagai root -> samakan owner ke APP_UID/APP_GID lalu beri akses
    chown -R "$APP_UID:$APP_GID" "$APP_DIR/storage" "$APP_DIR/bootstrap/cache" 2>/dev/null || true
    chmod -R 775 "$APP_DIR/storage" "$APP_DIR/bootstrap/cache" 2>/dev/null || true
else
    # Container berjalan sebagai non-root -> chmod sebisanya (butuh kita sebagai owner file)
    chmod -R ug+rwX "$APP_DIR/storage" "$APP_DIR/bootstrap/cache" 2>/dev/null \
        || echo '    (dilewati: bukan owner. Perbaiki sekali di HOST: sudo chown -R $(id -u):$(id -g) laravel-test/storage laravel-test/bootstrap/cache)'
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