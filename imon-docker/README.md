# imon-docker — ekosistem Docker untuk aplikasi ItemMonitoring

Satu folder = satu ekosistem = satu `docker compose` (pola sama dengan
`app-laravel-docker` milik AttendApp dan `ithelper-docker`).

| Item | Nilai |
|---|---|
| Container | `imon-app` (PHP-FPM 8.2) + `imon-nginx` |
| Network | `shared-network` (external, dipakai semua aplikasi) |
| Database | PostgreSQL BERSAMA `postgres-db`, database `item_monitoring`, role `imon` |
| Redis | **tidak dipakai** (`CACHE_DRIVER=file`, `SESSION_DRIVER=file`) |
| Port host (HTTP) | `8103` → port container `8082` (reverse-proxy) → `imon-nginx:80` |
| Domain (HTTPS) | `https://imon.kovcc.web.id` (port 443, sertifikat Let's Encrypt) |
| Kode aplikasi | `${LARAVEL_APP_PATH}` default `../../ItemMonitoring` |

> Aplikasi ini **belum memakai database** untuk fiturnya (halaman statis di
> `public/*.html`), tetapi koneksi PostgreSQL sudah disiapkan agar siap dipakai
> tanpa mengubah infra. Migrasi bawaan Laravel tetap dijalankan
> (`RUN_MIGRATIONS=true`) sehingga database `item_monitoring` terisi tabel dasar.

## Struktur

```
docker-ecosystem/
├── imon-docker/
│   ├── docker-compose.yml     # imon-app + imon-nginx
│   ├── .env.docker            # environment container (di-commit, dibaca CI)
│   ├── Dockerfile             # php:8.2-fpm-alpine + pdo_pgsql + opcache
│   ├── entrypoint.sh          # permission, APP_KEY, tunggu PG, composer, migrate, cache
│   ├── nginx/default.conf     # gzip, cache header, keepalive FPM, fastcgi HTTPS param
│   └── php/{www.conf,opcache.ini,selfcheck.php}
└── reverse-proxy-docker/
    └── nginx/default.conf     # blok `listen 8082` -> imon-nginx:80
```

## Nama container & DNS (penting)

Service di sini bernama `imon-app` dan `imon-nginx` — **bukan** `app` /
`laravel-nginx`. Compose mendaftarkan nama service sebagai alias DNS, jadi nama
yang sama akan bertabrakan dengan AttendApp di `shared-network`
(`fastcgi_pass app:9000` bisa nyasar ke aplikasi lain).

```bash
docker network inspect shared-network -f '{{range .Containers}}{{.Names}} {{end}}'
```

## Deploy pertama kali

```bash
docker network inspect shared-network >/dev/null || docker network create shared-network
cd ~/projects/docker-ecosystem/db-postgres-docker && docker compose up -d
cd ../reverse-proxy-docker && docker compose up -d

# database & role (sekali saja, aman diulang)
cd ~/projects/docker-ecosystem
docker exec -i postgres-db psql -U postgres -v ON_ERROR_STOP=1 \
  < db-postgres-docker/postgres/conf.d/20-app-databases.sql

cd imon-docker
docker compose up -d --build
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8103/login   # harus 200
```

## Deploy rutin

```bash
cd ~/projects/ItemMonitoring && git pull --ff-only
cd ~/projects/docker-ecosystem/imon-docker
docker compose up -d --force-recreate imon-app
```

## Deploy otomatis (GitHub Actions di repo aplikasi)

Workflow `.github/workflows/deploy.yml` milik repo **ItemMonitoring** hanya
menyentuh repo aplikasi; ia **tidak** menyentuh folder infra ini:

```bash
git pull --ff-only origin main        # di $VPS_APP_PATH (repo aplikasi)
composer install                      # hanya bila composer.json/lock berubah
docker restart imon-app               # entrypoint: migrate + cache, OPcache reset
curl http://127.0.0.1:8103/login      # harus 200 (maks 180 detik)
```

**Tidak ada** `git pull` / `docker compose` / cek network / cek `postgres-db` di
`docker-ecosystem` dari CI. Semua perubahan infra (`docker-compose.yml`,
`Dockerfile`, `nginx/`, `php/`, `.env.docker`, SQL database, DNS, SSL) tetap
**manual** di VPS.

Nama container & URL health bisa diubah per repo tanpa mengedit YAML:
**Settings** → **Secrets and variables** → **Actions** → tab **Variables**
(`APP_CONTAINER`, `HEALTH_URL`).

Kalau step **Deploy via SSH** gagal, penyebabnya selalu tercetak: script memakai
`exec 2>&1` (stderr ikut tampil) dan tidak memakai `set -e`. Container `paused`
di-`unpause` dulu, container berhenti di-`start`, dan nama container dicari
otomatis bila berbeda dari `imon-app`. Panduan lengkap ada di `../README.md`
bagian *Kalau step "Deploy via SSH" gagal*.

## Mengaktifkan HTTPS

```bash
cd ~/projects/docker-ecosystem
sudo bash tools/enable-https.sh imon.kovcc.web.id email-anda@gmail.com \
     --upstream imon-nginx:80
```

Prasyarat: A record `imon.kovcc.web.id` → IP VPS, port 80 & 443 terbuka.

## Catatan khusus aplikasi ini

- Route `/`, `/login`, `/dashboard` mengirim file statis dari `public/*.html`.
  Kalau file itu tidak ada di server, halaman akan 404 walau container sehat:
  `docker compose exec imon-app ls public/*.html`
- Aset front-end ada di `public/js` — pastikan ikut ter-commit di repo aplikasi.
- `APP_URL=https://imon.kovcc.web.id`: dipakai untuk membentuk URL absolut.
  Jangan memaksa `https` di kode aplikasi, karena jalur `http://IP_VPS:8103`
  akan ikut rusak. Skema dideteksi dari header `X-Forwarded-Proto`
  (`App\Http\Middleware\TrustProxies`, `$proxies = '*'`).
- `APP_KEY` sengaja **tidak** diisi di `.env.docker` (lihat `ithelper-docker/README.md`
  bagian APP_KEY untuk alasannya): entrypoint memakai kunci valid dari
  `ItemMonitoring/.env`, atau membuatnya lalu menyimpannya ke sana.

## Troubleshooting cepat

| Gejala | Penyebab & solusi |
|---|---|
| `502` dari `:8103` | Container `imon-app` masih start / crash: `docker compose logs --tail 60 imon-app` |
| `404` di semua halaman | `public/index.html` dkk tidak ada: `docker compose exec imon-app ls -la public` |
| `could not translate host name "postgres-db"` | `postgres-db` tidak ada di `shared-network` |
| `password authentication failed for user "imon"` | Jalankan `20-app-databases.sql`, cocokkan `DB_PASSWORD` |
| CSS/JS tidak load saat HTTPS | `TrustProxies::$proxies = '*'` belum ada di repo aplikasi |
| 500 saat request | `docker exec imon-app php /usr/local/bin/app-selfcheck.php` |

## Perintah harian

```bash
docker compose ps
docker compose logs -f imon-app
docker compose restart imon-nginx
docker compose up -d --force-recreate imon-app   # wajib setelah perubahan PHP
```
