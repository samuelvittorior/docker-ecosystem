#!/bin/sh
# =============================================================================
# Entrypoint Laravel - container imon-app (PHP-FPM)
#
# Urutan kerja:
#   1. Menyiapkan direktori storage & bootstrap/cache + permission
#   2. Memastikan APP_KEY valid (kalau tidak, dibuat & disimpan ke .env)
#   3. Menunggu PostgreSQL siap  <-- TIDAK ADA pengecekan Redis (app ini file-based)
#   4. composer install bila vendor/ belum ada
#   5. storage:link
#   6. Buang cache lama, migrate, lalu bangun cache produksi
#   7. Uji cepat: APP_KEY + koneksi database
#
# Pola ini sama dengan app-laravel-docker/entrypoint.sh milik AttendApp.
# Bedanya HANYA: blok "Menunggu Redis" dan probe Redis dihapus, karena
# ItemMonitoring memakai CACHE_DRIVER=file + SESSION_DRIVER=file.
# =============================================================================
set -e

APP_DIR=/var/www/html

# Composer dijalankan sebagai root di dalam container -> izinkan tanpa prompt.
export COMPOSER_ALLOW_SUPERUSER=1
# "home" Composer diarahkan ke folder yang pasti bisa ditulis.
export COMPOSER_HOME="${COMPOSER_HOME:-/tmp/composer}"
mkdir -p "$COMPOSER_HOME"

# -----------------------------------------------------------------------------
# Git "dubious ownership".
# Folder aplikasi di-bind-mount dari VPS dan dimiliki user HOST, sedangkan proses
# di container berjalan sebagai ROOT. Git modern menolak repo milik UID lain:
#   fatal: detected dubious ownership in repository at '/var/www/html'
# -----------------------------------------------------------------------------
if command -v git >/dev/null 2>&1; then
    git config --global --add safe.directory "$APP_DIR" 2>/dev/null || true
fi

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
# Perbaikan permission (pengganti chmod manual di host).
# Laravel WAJIB bisa MENULIS ke: storage/ dan bootstrap/cache/.
# -----------------------------------------------------------------------------
echo "==> Memperbaiki permission storage & bootstrap/cache (owner: $FPM_USER)..."
if [ "$(id -u)" = "0" ]; then
    chown -R "$FPM_USER:$FPM_GROUP" "$APP_DIR/storage" "$APP_DIR/bootstrap/cache" 2>/dev/null || true
    chmod -R 775 "$APP_DIR/storage" "$APP_DIR/bootstrap/cache" 2>/dev/null || true
else
    chmod -R ug+rwX "$APP_DIR/storage" "$APP_DIR/bootstrap/cache" 2>/dev/null \
        || echo "!! Tidak bisa memperbaiki permission (bukan root). Jalankan di HOST: sudo chown -R $FPM_USER:$FPM_GROUP storage bootstrap/cache"
fi

# -----------------------------------------------------------------------------
# APP_KEY.
#
# Laravel memakainya untuk enkripsi cookie & session. Tanpa kunci valid, SEMUA
# request berakhir HTTP 500 dengan:
#   RuntimeException: The only supported ciphers are AES-128-CBC and
#   AES-256-CBC with the correct key lengths.
#
# Yang diterima Laravel: "base64:" + base64 dari TEPAT 32 byte, ATAU 32
# karakter mentah. Placeholder pendek (mis. "SI_SECRET_APIKEY_XXXX" = 25
# karakter) SELALU gagal.
#
# Sumber kunci, berurutan:
#   1. environment container (imon-docker/.env.docker) -> paling utama
#   2. baris APP_KEY di $APP_DIR/.env (kalau .env.docker tidak mengisinya)
#   3. dibuat otomatis lalu DITULIS ke $APP_DIR/.env agar tidak berubah-ubah
#      setiap restart (session pengguna tidak hangus).
#
# Catatan: bila APP_KEY diisi di .env.docker, nilai itu MENANG atas .env
# (Laravel memakai dotenv immutable: env yang sudah ada tidak ditimpa).
# -----------------------------------------------------------------------------
app_key_valid() {
    php -r '
        $k = (string) (getenv("APP_KEY") ?: "");
        if ($k === "") { exit(1); }
        if (strpos($k, "base64:") === 0) { $k = (string) base64_decode(substr($k, 7), true); }
        exit(strlen($k) === 32 ? 0 : 1);
    ' >/dev/null 2>&1
}

# APP_KEY valid tidak dikirim lewat environment -> coba ambil dari .env
if ! app_key_valid && [ -f "$APP_DIR/.env" ]; then
    KUNCI_ENV="$(grep -m1 '^APP_KEY=' "$APP_DIR/.env" 2>/dev/null | cut -d= -f2- | tr -d '\r"' || true)"
    if [ -n "$KUNCI_ENV" ]; then
        APP_KEY="$KUNCI_ENV"
        export APP_KEY
    fi
fi

if ! app_key_valid; then
    if [ -n "${APP_KEY:-}" ]; then
        echo "!! APP_KEY terisi tetapi TIDAK VALID (butuh 'base64:' 32 byte atau 32 karakter)."
    else
        echo "!! APP_KEY kosong."
    fi
    # Dibuat acak & benar-benar valid (32 byte) -- bukan placeholder statis,
    # karena kunci statis yang bocor membuat semua instalasi bisa saling
    # membaca cookie/session terenkripsi.
    KUNCI_BARU="base64:$(php -r 'echo base64_encode(random_bytes(32));')"
    APP_KEY="$KUNCI_BARU"
    export APP_KEY

    if [ -f "$APP_DIR/.env" ] && grep -q '^APP_KEY=' "$APP_DIR/.env" 2>/dev/null; then
        sed -i "s|^APP_KEY=.*|APP_KEY=${KUNCI_BARU}|" "$APP_DIR/.env" 2>/dev/null \
            && echo "!! APP_KEY baru disimpan ke $APP_DIR/.env"
    elif [ -f "$APP_DIR/.env" ]; then
        printf '\nAPP_KEY=%s\n' "$KUNCI_BARU" >> "$APP_DIR/.env" \
            && echo "!! APP_KEY baru ditambahkan ke $APP_DIR/.env"
    else
        # .env belum ada: buat minimal agar kunci tersimpan permanen.
        printf 'APP_NAME=ItemMonitoring\nAPP_ENV=production\nAPP_DEBUG=false\nAPP_KEY=%s\n' "$KUNCI_BARU" \
            > "$APP_DIR/.env"
        chown "$FPM_USER:$FPM_GROUP" "$APP_DIR/.env" 2>/dev/null || true
        echo "!! .env belum ada -> dibuat dengan APP_KEY baru."
    fi
    echo "!! Kunci tersimpan di $APP_DIR/.env (jangan di-commit; sudah ada di .gitignore Laravel)."
    echo "!! Untuk mengunci nilainya di infra, salin ke imon-docker/.env.docker:"
    echo "!!   APP_KEY=$KUNCI_BARU"
fi

# -----------------------------------------------------------------------------
# Tunggu PostgreSQL siap.
#
# Container app bisa start sebelum PostgreSQL siap (compose terpisah), sehingga
# `php artisan migrate` akan gagal bila dijalankan terlalu cepat.
#
# `pg_isready` dipakai (bukan /dev/tcp) karena image ini berbasis Alpine:
# /bin/sh = BusyBox ash yang TIDAK mendukung fitur bash /dev/tcp.
# -----------------------------------------------------------------------------
echo "==> Menunggu PostgreSQL siap (${DB_HOST:-postgres-db}:${DB_PORT:-5432})..."
for i in $(seq 1 60); do
    if pg_isready -h "${DB_HOST:-postgres-db}" -p "${DB_PORT:-5432}" -U "${DB_USERNAME:-imon}" >/dev/null 2>&1; then
        echo "==> PostgreSQL siap."
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "!! PostgreSQL belum siap setelah 60 detik, lanjutkan tetap saja."
        echo "!! Pastikan container postgres-db berjalan dan ada di network shared-network."
    fi
    sleep 1
done

# Install dependency Composer bila vendor belum ada (first deploy).
# Bila GAGAL, hentikan dengan pesan jelas: kalau dibiarkan, PHP-FPM tetap
# dijalankan tanpa autoloader dan semua request berakhir "500 / Class not found",
# sementara Docker me-restart container terus-menerus.
if [ ! -f "$APP_DIR/vendor/autoload.php" ]; then
    echo "==> vendor/ belum ada, menjalankan composer install..."
    if ! composer install --no-dev --optimize-autoloader --no-interaction --prefer-dist; then
        echo "!! composer install GAGAL. Entrypoint berhenti supaya PHP-FPM TIDAK"
        echo "!! dijalankan tanpa autoloader (kalau dibiarkan, semua request jadi"
        echo "!! '500 Class not found'). Docker akan mencoba start ulang; pesan"
        echo "!! penyebabnya ada tepat di atas baris ini. Penyebab tersering:"
        echo "!!   * composer.lock tidak kompatibel dengan versi PHP container"
        echo "!!   * koneksi internet container terputus"
        exit 1
    fi
fi

# Symlink public/storage -> storage/app/public
if [ ! -L "$APP_DIR/public/storage" ]; then
    echo "==> Membuat symlink storage..."
    php artisan storage:link || true
fi

# -----------------------------------------------------------------------------
# Perbaiki ulang permission SETELAH composer install / pembuatan .env.
# Composer berjalan sebagai root sehingga file baru (termasuk
# bootstrap/cache/packages.php & services.php) dimiliki root, sedangkan worker
# PHP-FPM (www-data) harus bisa menimpanya saat cache dibuat ulang.
# -----------------------------------------------------------------------------
if [ "$(id -u)" = "0" ]; then
    chown -R "$FPM_USER:$FPM_GROUP" "$APP_DIR/storage" "$APP_DIR/bootstrap/cache" 2>/dev/null || true
fi

# -----------------------------------------------------------------------------
# WAJIB: buang cache LAMA sebelum migrate & optimize.
#
# Laravel SELALU memakai bootstrap/cache/config.php bila file itu ada dan
# MELEWATI .env sama sekali (LoadConfiguration::bootstrap). Jadi cache basi =
# aplikasi memakai nilai lama (DB_HOST/APP_KEY) walaupun .env.docker sudah
# diubah. File itu ada di .gitignore aplikasi, sehingga `git pull` TIDAK
# menghapusnya.
# -----------------------------------------------------------------------------
if [ -f "$APP_DIR/vendor/autoload.php" ]; then
    echo "==> Menghapus cache lama (config/route/view/cache)..."
    php artisan optimize:clear >/dev/null 2>&1 || true

    # Jaring pengaman bila optimize:clear gagal (mis. permission):
    #   config.php    -> sumber nilai config basi
    #   routes-v7.php -> sumber TypeError saat route:cache (Laravel 8)
    # Keduanya dibuat ulang oleh blok RUN_OPTIMIZE di bawah.
    for stale in config.php routes-v7.php; do
        if [ -f "$APP_DIR/bootstrap/cache/$stale" ]; then
            rm -f "$APP_DIR/bootstrap/cache/$stale" 2>/dev/null \
                && echo "    dihapus paksa (basi): bootstrap/cache/$stale"
        fi
    done
fi

# Migrasi database otomatis (opsional, lewat RUN_MIGRATIONS=true)
if [ "$RUN_MIGRATIONS" = "true" ]; then
    echo "==> Menjalankan migrasi database..."
    php artisan migrate --force || echo "!! migrate gagal (cek koneksi DB / SQL khusus MySQL)"
fi

# Optimasi cache produksi (opsional, lewat RUN_OPTIMIZE=true)
if [ "$RUN_OPTIMIZE" = "true" ]; then
    echo "==> Membuat cache konfigurasi/route/view..."
    php artisan config:cache || echo "!! config:cache gagal"
    php artisan route:cache  || echo "!! route:cache gagal (rute tetap jalan tanpa cache)"
    php artisan view:cache   || echo "!! view:cache gagal"

    # Cache baru ditulis sebagai root -> kembalikan kepemilikannya.
    if [ "$(id -u)" = "0" ]; then
        chown -R "$FPM_USER:$FPM_GROUP" "$APP_DIR/storage" "$APP_DIR/bootstrap/cache" 2>/dev/null || true
    fi

    # ---------------------------------------------------------------------
    # Uji cepat: laporkan nilai yang BENAR-BENAR dipakai Laravel (hasil merge
    # .env.docker + config cache), bukan tebakan dari file .env.
    # Kalau muncul "GAGAL" di sini, penyebab HTTP 500 sudah pasti.
    # ---------------------------------------------------------------------
    if [ -f "$APP_DIR/vendor/autoload.php" ]; then
        php /usr/local/bin/app-selfcheck.php 2>&1 || echo "!! self-check gagal dijalankan"
    fi
fi

echo "==> Entrypoint selesai. Menjalankan: $*"
exec "$@"

