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
#
# PENTING: APP_KEY harus punya panjang yang BENAR untuk AES-256-CBC.
# Laravel menerima dua bentuk:
#   a) "base64:" + base64 dari TEPAT 32 byte   (paling aman)
#   b) 32 karakter mentah
# Placeholder seperti "SI_SECRET_APIKEY_XXXX" hanya 25 karakter sehingga
# Laravel melempar:
#   RuntimeException: The only supported ciphers are AES-128-CBC and
#   AES-256-CBC with the correct key lengths.
# dan SEMUA request berakhir HTTP 500 (cookie & session tidak bisa dienkripsi).
# -----------------------------------------------------------------------------
app_key_valid() {
    php -r '
        $k = (string) (getenv("APP_KEY") ?: "");
        if ($k === "") { exit(1); }
        if (strpos($k, "base64:") === 0) { $k = (string) base64_decode(substr($k, 7), true); }
        exit(strlen($k) === 32 ? 0 : 1);
    ' >/dev/null 2>&1
}

if ! app_key_valid; then
    if [ -n "${APP_KEY:-}" ]; then
        echo "!! APP_KEY terisi tetapi TIDAK VALID (butuh 'base64:' 32 byte atau 32 karakter)."
    else
        echo "!! APP_KEY kosong."
    fi
    # Dibuat acak & benar-benar valid (32 byte). TIDAK memakai placeholder
    # statis, karena kunci statis yang bocor = semua instalasi bisa saling
    # membaca cookie/session terenkripsi.
    APP_KEY="base64:$(php -r 'echo base64_encode(random_bytes(32));')"
    export APP_KEY
    echo "!! Dipakai APP_KEY SEMENTARA -> session & cookie lama hangus setiap restart."
    echo "!! Set permanen di app-laravel-docker/.env.docker (buat: php artisan key:generate --show):"
    echo "!!   APP_KEY=$APP_KEY"
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
    # Kode keluar dari pemeriksa di bawah:
    #   0 = Redis hidup DAN (bila ada password) AUTH berhasil
    #   1 = belum bisa dihubungi -> tunggu & ulangi
    #   2 = Redis HIDUP tetapi AUTH DITOLAK (password beda) -> tidak ada
    #       gunanya mengulang, laporkan sekarang.
    redis_rc=0
    php -r '
        $host = getenv("REDIS_HOST") ?: "redis-shared";
        $port = (int) (getenv("REDIS_PORT") ?: 6379);
        $pass = getenv("REDIS_PASSWORD");
        $fp = @fsockopen($host, $port, $errno, $errstr, 1.0);
        if (!$fp) { exit(1); }
        if ($pass && $pass !== "null") {
            fwrite($fp, "AUTH " . $pass . "\r\n");
            $line = (string) fgets($fp, 128);
            fclose($fp);
            // "-NOAUTH Authentication required" / "-WRONGPASS ..." =
            // server hidup tapi kredensial kita SALAH.
            exit(strpos($line, "+OK") === 0 ? 0 : 2);
        }
        fclose($fp);
        exit(0);
    ' >/dev/null 2>&1 || redis_rc=$?

    if [ "$redis_rc" -eq 0 ]; then
        echo "==> Redis siap."
        break
    fi

    if [ "$redis_rc" -eq 2 ]; then
        echo "!! Redis HIDUP tetapi AUTH DITOLAK (balasan -NOAUTH/-WRONGPASS)."
        echo "!! REDIS_PASSWORD di app-laravel-docker/.env.docker TIDAK sama dengan"
        echo "!! requirepass di redis-shared-docker/.env.docker."
        echo "!! Laravel akan melempar 'RedisException: NOAUTH Authentication required' -> HTTP 500."
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

# -----------------------------------------------------------------------------
# WAJIB: buang cache LAMA sebelum migrate & optimize.
#
# Laravel SELALU memakai bootstrap/cache/config.php bila file itu ada, dan
# melewati .env sama sekali. Bukti di framework (v8.83):
#   Illuminate\Foundation\Bootstrap\LoadConfiguration::bootstrap()
#     if (file_exists($cached = $app->getCachedConfigPath())) {
#         $items = require $cached; $loadedFromCache = true;
#     }
#     if (! isset($loadedFromCache)) { $this->loadConfigurationFiles(...); }
# Jadi file cache yang BASI = aplikasi memakai nilai lama (host/password Redis,
# APP_KEY, koneksi DB) walaupun .env.docker sudah diubah.
#
# Kenapa file basi bisa bertahan?
#   * RUN_OPTIMIZE tidak "true" -> cache lama tidak pernah dibangun ulang;
#   * folder aplikasi di-copy dari komputer lokal. `bootstrap/cache/*.php`
#     ada di .gitignore aplikasi, jadi `git pull` TIDAK menghapusnya;
#   * proses pembuat cache gagal/di-skip.
# Gejala khas: `php artisan tinker` menampilkan redis.host = `redis` (nilai
# lama) padahal env container = `redis-shared`; error NOAUTH; HTTP 500.
#
# `route:cache` pun gagal bila routes-v7.php basi masih bisa dimuat ulang:
#   TypeError: RouteCacheCommand::buildRouteCacheFile(): Argument #1 ($routes)
#   must be of type RouteCollection, CompiledRouteCollection given
# -----------------------------------------------------------------------------
if [ -f "$APP_DIR/vendor/autoload.php" ]; then
    echo "==> Menghapus cache lama (config/route/view/cache)..."
    php artisan optimize:clear >/dev/null 2>&1 || true

    # Jaring pengaman: kalau optimize:clear gagal menghapus (mis. file milik user
    # lain / permission), hapus langsung. Dua file ini inti masalahnya:
    #   config.php     -> sumber nilai config basi (dipakai Laravel, .env diabaikan)
    #   routes-v7.php  -> sumber TypeError saat route:cache
    # Keduanya akan dibuat ulang oleh blok RUN_OPTIMIZE di bawah.
    for stale in config.php routes-v7.php; do
        if [ -f "$APP_DIR/bootstrap/cache/$stale" ]; then
            rm -f "$APP_DIR/bootstrap/cache/$stale" 2>/dev/null \
                && echo "    dihapus paksa (basi): bootstrap/cache/$stale"
        fi
    done
fi

# Migrasi database otomatis (opsional)
if [ "$RUN_MIGRATIONS" = "true" ]; then
    echo "==> Menjalankan migrasi database..."
    php artisan migrate --force || echo "!! migrate gagal (cek koneksi DB)"
fi

# Optimasi cache untuk produksi (opsional)
if [ "$RUN_OPTIMIZE" = "true" ]; then
    echo "==> Membuat cache konfigurasi/route/view..."
    # Cache lama sudah dibersihkan di atas, jadi di sini selalu ditulis cache
    # BARU dari .env.docker yang berlaku saat ini.
    # (`config:cache`/`route:cache` memang sudah memanggil `*:clear` sendiri,
    #  TETAPI hanya bila langkah ini benar-benar dijalankan -- dan langkah ini
    #  hanya dijalankan bila RUN_OPTIMIZE=true.)
    php artisan config:cache || echo "!! config:cache gagal"
    php artisan route:cache  || echo "!! route:cache gagal (rute tetap jalan tanpa cache)"
    php artisan view:cache   || echo "!! view:cache gagal"

    # Cache baru ditulis sebagai root -> kembalikan kepemilikannya agar
    # www-data bisa menimpanya pada deploy berikutnya.
    if [ "$(id -u)" = "0" ]; then
        chown -R "$FPM_USER:$FPM_GROUP" "$APP_DIR/storage" "$APP_DIR/bootstrap/cache" 2>/dev/null || true
    fi

    # ---------------------------------------------------------------------
    # Uji cepat: laporkan nilai Redis/DB yang BENAR-BENAR dipakai Laravel
    # (hasil merge .env.docker + config cache), bukan tebakan dari .env.
    # Bila muncul "Redis: GAGAL" di sini, penyebab HTTP 500 sudah pasti.
    # ---------------------------------------------------------------------
    if [ -f "$APP_DIR/vendor/autoload.php" ]; then
        cat > /tmp/app-selfcheck.php <<'PHP'
<?php
require '/var/www/html/vendor/autoload.php';
$app = require '/var/www/html/bootstrap/app.php';
try {
    $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
} catch (Throwable $e) {
    echo "    bootstrap GAGAL -> " . get_class($e) . ": " . $e->getMessage() . "\n";
    exit(0);
}
printf(
    "    config efektif -> redis.host=%s redis.db=%s cache=%s session=%s db=%s\n",
    config('database.redis.default.host'),
    config('database.redis.default.database'),
    config('cache.default'),
    config('session.driver'),
    config('database.default')
);
$probes = [
    // Mengenkripsi sungguhan: gagal bila APP_KEY salah panjang
    // ("The only supported ciphers are AES-128-CBC and AES-256-CBC with the
    //  correct key lengths") -> inilah penyebab 500 yang sulit dilacak.
    'APP_KEY'  => function () { Illuminate\Support\Facades\Crypt::encryptString('ok'); },
    'Redis'    => function () { Illuminate\Support\Facades\Redis::connection()->ping(); },
    'Database' => function () { Illuminate\Support\Facades\DB::connection()->getPdo(); },
];
foreach ($probes as $label => $probe) {
    try {
        $probe();
        echo "    $label: OK\n";
    } catch (Throwable $e) {
        echo "    $label: GAGAL -> " . $e->getMessage() . "\n";
    }
}
PHP
        php /tmp/app-selfcheck.php 2>&1 || echo "!! self-check gagal dijalankan"
    fi
fi

echo "==> Entrypoint selesai. Menjalankan: $*"
exec "$@"