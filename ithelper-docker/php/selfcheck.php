<?php
/**
 * =============================================================================
 * Self-check konfigurasi efektif (dipakai entrypoint, bukan web).
 *
 * Menjawab pertanyaan: "nilai apa yang SEBENARNYA dipakai Laravel?" -- bukan
 * tebakan dari isi file .env. Berguna karena `bootstrap/cache/config.php`
 * yang basi bisa menimpa .env.docker tanpa terlihat.
 *
 * Kalau ada baris "GAGAL", penyebab HTTP 500 sudah pasti:
 *   APP_KEY  GAGAL -> kunci salah panjang (cookie/session tidak bisa dienkripsi)
 *   Database GAGAL -> DB_HOST/DB_USERNAME/DB_PASSWORD salah, atau role/database
 *                     belum dibuat (lihat db-postgres-docker/postgres/conf.d/)
 *
 * Dijalankan di dalam container:  php /usr/local/bin/app-selfcheck.php
 * =============================================================================
 */

require '/var/www/html/vendor/autoload.php';

$app = require '/var/www/html/bootstrap/app.php';

try {
    $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
} catch (Throwable $e) {
    echo '    bootstrap GAGAL -> ' . get_class($e) . ': ' . $e->getMessage() . "\n";
    exit(0);
}

printf(
    "    config efektif -> app_env=%s debug=%s cache=%s session=%s db=%s host=%s\n",
    config('app.env'),
    var_export(config('app.debug'), true),
    config('cache.default'),
    config('session.driver'),
    config('database.default'),
    config('database.connections.pgsql.host')
);

$probes = [
    // Mengenkripsi sungguhan: gagal bila APP_KEY salah panjang.
    'APP_KEY'  => function () {
        Illuminate\Support\Facades\Crypt::encryptString('ok');
    },
    'Database' => function () {
        Illuminate\Support\Facades\DB::connection()->getPdo();
    },
];

foreach ($probes as $label => $probe) {
    try {
        $probe();
        echo "    $label: OK\n";
    } catch (Throwable $e) {
        echo "    $label: GAGAL -> " . $e->getMessage() . "\n";
    }
}
