# ithelper-docker — ekosistem Docker untuk aplikasi ITHelper

Satu folder = satu ekosistem = satu `docker compose` (pola sama dengan
`app-laravel-docker` milik AttendApp).

| Item | Nilai |
|---|---|
| Container | `ithelper-app` (PHP-FPM 8.1) + `ithelper-nginx` |
| Network | `shared-network` (external, dipakai semua aplikasi) |
| Database | PostgreSQL BERSAMA `postgres-db`, database `ithelper`, role `ithelper` |
| Redis | **tidak dipakai** (`CACHE_DRIVER=file`, `SESSION_DRIVER=file`) |
| Port host (HTTP) | `8102` → port container `8081` (reverse-proxy) → `ithelper-nginx:80` |
| Domain (HTTPS) | `https://desk.kovcc.web.id` (port 443, sertifikat Let's Encrypt) |
| Kode aplikasi | `${LARAVEL_APP_PATH}` default `../../ITHelper` (folder sibling) |

## Struktur

```
docker-ecosystem/
├── ithelper-docker/
│   ├── docker-compose.yml     # ithelper-app + ithelper-nginx
│   ├── .env.docker            # environment container (di-commit, dibaca CI)
│   ├── Dockerfile             # php:8.1-fpm-alpine + pdo_pgsql + opcache
│   ├── entrypoint.sh          # permission, APP_KEY, tunggu PG, composer, migrate, cache
│   ├── nginx/default.conf     # gzip, cache header, keepalive FPM, fastcgi HTTPS param
│   └── php/{www.conf,opcache.ini,selfcheck.php}
└── reverse-proxy-docker/
    └── nginx/default.conf     # blok `listen 8081` -> ithelper-nginx:80
```

## Nama container & DNS (penting)

Compose mendaftarkan **nama service** sebagai alias DNS di network. Karena itu
service di sini bernama `ithelper-app` dan `ithelper-nginx`, **bukan** `app` /
`laravel-nginx` seperti AttendApp. Kalau namanya sama, akan ada dua container
yang menjawab nama `app` di `shared-network`, dan `fastcgi_pass app:9000` milik
AttendApp bisa mendarat ke PHP-FPM aplikasi ini (502/504 muncul-hilang).

Verifikasi di VPS (tidak boleh ada nama dobel):

```bash
docker network inspect shared-network -f '{{range .Containers}}{{.Names}} {{end}}'
```

## Deploy pertama kali

```bash
# 0) Prasyarat: network + PostgreSQL + reverse proxy sudah jalan
docker network inspect shared-network >/dev/null || docker network create shared-network
cd ~/projects/docker-ecosystem/db-postgres-docker && docker compose up -d
cd ../reverse-proxy-docker && docker compose up -d

# 1) Buat database & role (SEKALI saja; aman dijalankan berulang)
cd ~/projects/docker-ecosystem
docker exec -i postgres-db psql -U postgres -v ON_ERROR_STOP=1 \
  < db-postgres-docker/postgres/conf.d/20-app-databases.sql

# 2) Nyalakan aplikasi
cd ithelper-docker
docker compose up -d --build

# 3) Tunggu sampai siap (entrypoint butuh 10-60 detik)
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8102/login   # harus 200
```

## Deploy rutin (setelah kode berubah)

```bash
cd ~/projects/ITHelper && git pull --ff-only
cd ~/projects/docker-ecosystem/ithelper-docker
docker compose up -d --force-recreate ithelper-app   # WAJIB: OPcache tidak revalidate
```

> `opcache.validate_timestamps=0` → kode lama tetap dipakai dari RAM sampai
> container di-recreate. `reload` saja tidak cukup.

## Deploy otomatis (GitHub Actions di repo aplikasi)

Workflow `.github/workflows/deploy.yml` milik repo **ITHelper** hanya menyentuh
repo aplikasi; ia **tidak** menyentuh folder infra ini:

```bash
git pull --ff-only origin main        # di $VPS_APP_PATH (repo aplikasi)
composer install                      # hanya bila composer.json/lock berubah
docker restart ithelper-app           # entrypoint: migrate + cache, OPcache reset
curl http://127.0.0.1:8102/login      # harus 200 (maks 180 detik)
```

Konsekuensinya:

- **Tidak ada** `git pull` / `docker compose` / cek network / cek `postgres-db`
  di `docker-ecosystem` dari CI. Semua perubahan infra (`docker-compose.yml`,
  `Dockerfile`, `nginx/`, `php/`, `.env.docker`, SQL database, DNS, SSL) tetap
  **manual** di VPS seperti dijelaskan di atas.
- Nama container & URL health bisa diubah per repo: **Settings** →
  **Secrets and variables** → **Actions** → tab **Variables**
  (`APP_CONTAINER`, `HEALTH_URL`).
- `docker restart` cukup karena kode di-mount dan `opcache.validate_timestamps=0`
  hanya bisa direset dengan memulai ulang PHP-FPM.
- Kalau step **Deploy via SSH** gagal, penyebabnya selalu tercetak: workflow
  memakai `ssh` biasa (bukan `appleboy/ssh-action`) dan mengirim script lewat
  `bash -s`, jadi stderr + exit code asli terlihat. Tiap perintah dicetak dengan
  `exit=0/1`, ada `trap` yang menunjukkan baris yang mati, container `paused`
  di-`unpause` dulu, container berhenti di-`start`, dan nama container dicari
  otomatis bila berbeda dari `ithelper-app`. Log lengkap juga tersimpan di
  `/tmp/deploy-ithelper.log` pada VPS. Panduan ada di `../README.md` bagian
  *Cara deploy dijalankan*.

## Mengaktifkan HTTPS

```bash
cd ~/projects/docker-ecosystem
sudo bash tools/enable-https.sh desk.kovcc.web.id email-anda@gmail.com \
     --upstream ithelper-nginx:80
```

Prasyarat: A record `desk.kovcc.web.id` → IP VPS, port 80 & 443 terbuka.
Skrip ini membuat `reverse-proxy-docker/nginx/extra/desk.kovcc.web.id.conf`
(HTTP/2 + HSTS + redirect 80→443) tanpa mematikan proxy.

Setelah HTTPS aktif, `APP_URL` di `.env.docker` sudah benar
(`https://desk.kovcc.web.id`). **Jangan** menambah `URL::forceScheme('https')`
di aplikasi: jalur `http://IP_VPS:8102` akan ikut dipaksa https dan rusak.
Skema dideteksi dari `X-Forwarded-Proto` (lihat `App\Http\Middleware\TrustProxies`,
`$proxies = '*'`).

## APP_KEY

`APP_KEY` **tidak** diisi di `.env.docker` — itu disengaja. Kalau baris
`APP_KEY=` ada di env_file tetapi kosong, nilai kosong itulah yang menang atas
`.env` aplikasi (Laravel memakai dotenv immutable), sehingga semua request 500
dengan "The only supported ciphers are AES-128-CBC...".

Entrypoint menanganinya:

1. pakai `APP_KEY` dari `ITHelper/.env` bila valid (32 karakter / base64 32 byte)
2. kalau tidak ada/tidak valid: buat kunci acak valid lalu **simpan ke**
   `ITHelper/.env` (stabil antar restart, konsisten untuk FPM dan CLI)

Nilai yang benar-benar dipakai terlihat di `docker compose logs ithelper-app`.

## Migrasi MySQL → PostgreSQL (WAJIB dibaca)

Migrasi `2026_05_29_000002_make_laporan_optional_fields_nullable.php` versi lama
memakai `ALTER TABLE ... MODIFY`, sintaks **khusus MySQL**, sehingga gagal di
PostgreSQL:

```
SQLSTATE[42601]: Syntax error at or near "MODIFY"
```

Versi di repo ini sudah diperbaiki agar memilih perintah sesuai driver
(`pgsql` → `ALTER COLUMN ... DROP NOT NULL`, MySQL tetap `MODIFY`).
**Salin file itu ke repo asli ITHelper**, kalau tidak `migrate` akan berhenti di
sana dan tabel sesudahnya tidak pernah dibuat.

Cek sisa migrasi yang memakai SQL khusus MySQL:

```bash
cd ~/projects/ITHelper
grep -rn "DB::statement" database/migrations | grep -Ei "modify|engine=|fulltext"
```

## Troubleshooting cepat

| Gejala | Penyebab & solusi |
|---|---|
| `502` dari `:8102` | Container `ithelper-app` masih start (10-60 detik) atau crash. `docker compose logs --tail 60 ithelper-app` |
| `could not translate host name "postgres-db"` | `postgres-db` tidak ada di `shared-network`: `docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' postgres-db` |
| `password authentication failed for user "ithelper"` | Role belum dibuat / password beda. Jalankan `20-app-databases.sql`, lalu cocokkan `DB_PASSWORD` |
| `database "ithelper" does not exist` | File SQL belum dijalankan di VPS ini (volume lama tidak mengulang `initdb`) |
| `The only supported ciphers are AES-128-CBC...` | `APP_KEY` tidak valid. Entrypoint membuat & menyimpannya ke `ITHelper/.env`; cek log container |
| CSS/JS tidak load saat HTTPS | `TrustProxies::$proxies = '*'` belum ada di repo aplikasi |
| Halaman 500 | `docker exec ithelper-app php /usr/local/bin/app-selfcheck.php` → lihat baris `GAGAL` |

## Perintah harian

```bash
docker compose ps
docker compose logs -f ithelper-app
docker compose exec ithelper-app php artisan tinker
docker compose restart ithelper-nginx                  # perubahan nginx saja
docker compose up -d --force-recreate ithelper-app     # wajib untuk perubahan PHP
```

