# ðŸ³ Docker Ecosystem â€” Laravel + PostgreSQL + Redis + Nginx Reverse Proxy

Kumpulan **Docker Compose** yang terpisah namun saling terhubung lewat satu network
bersama (`shared-network`), dirancang untuk VPS kecil (RAM Â±6 GB) dan mudah di-scale
ke banyak aplikasi Laravel.

> Kode aplikasi Laravel **tidak** disimpan di repo ini. Repo ini hanya berisi
> konfigurasi infrastruktur. Kode aplikasi ada di repo terpisah (`attendapp`),
> dan di-mount ke container melalui volume `${LARAVEL_APP_PATH:-../../attendapp}`.

---

## ðŸ—ï¸ Arsitektur

```
                            Internet
                                |
                                v
              +----------------------------------+
              |  reverse-proxy (nginx:alpine)    |  port 80 / 443 / 8101
              |  app.attendapp.com               |
              +----------------+-----------------+
                               |  proxy_pass attendapp-nginx:80
                               v
              +----------------------------------+
              | attendapp-nginx (nginx:alpine)   |  listen 80
              | root: /var/www/html/public       |
              +----------------+-----------------+
                               |  fastcgi_pass app:9000
                               v
              +----------------------------------+
              | attendapp-app (php:8.2-fpm)      |
              | /var/www/html <- $LARAVEL_APP_PATH|
              +----+------------------------+----+
                   |                        |
                   | DB_HOST=postgres-db    | REDIS_HOST=redis-shared
                   v                        v
        +--------------------+   +--------------------+
        | postgres-db        |   | redis-shared       |
        | postgres:15-alpine |   | redis:alpine       |
        | (port tidak dibuka)|   | (port tidak dibuka)|
        +--------------------+   +--------------------+

        SEMUA container di atas berada di SATU network: shared-network
```

**Redis bersama:** Redis tidak lagi di dalam `app-laravel-docker`, melainkan
berdiri sendiri di `redis-shared-docker/` dan dipakai bersama beberapa aplikasi
lewat `shared-network` dengan nama `redis-shared`.

> **CATATAN Penting - Beda dengan PostgreSQL:** Redis **tidak** punya isolasi per-user seperti
> PostgreSQL. Setiap aplikasi **wajib** memakai nomor `REDIS_DB` /
> `REDIS_CACHE_DB` yang berbeda, kalau tidak `php artisan cache:clear` di satu
> aplikasi bisa menghapus cache aplikasi lain. Tabel alokasi nomor DB ada di
> [redis-shared-docker/README.md](redis-shared-docker/README.md).

**Peran tiap folder:**

| Folder | Isi | Port |
|--------|-----|------|
| `app-laravel-docker/` | PHP-FPM (Laravel) + Nginx internal | internal (9000, 80) |
| `redis-shared-docker/` | Redis BERSAMA untuk cache + session beberapa aplikasi | tidak diekspos |
| `db-postgres-docker/` | PostgreSQL 15 (dibuat pertama, membuat `shared-network`) | tidak diekspos |
| `reverse-proxy-docker/` | Nginx reverse proxy subdomain | 80, 443, **8101** (akses langsung tanpa domain) |
| `tools/` | Skrip bantu operasional (`diagnose.sh`, `reset-stack.sh`) | - |

---

## ðŸ“ Struktur Direktori yang Diharapkan di VPS

Kedua repo harus berada pada **folder induk yang sama** karena volume memakai
path relatif `${LARAVEL_APP_PATH:-../../attendapp}` (dihitung dari folder
`app-laravel-docker/`):

```
~/projects/
â”œâ”€â”€ docker-ecosystem/          â† repo ini
â”‚   â”œâ”€â”€ app-laravel-docker/
â”‚   â”œâ”€â”€ db-postgres-docker/
â”‚   â””â”€â”€ reverse-proxy-docker/
â””â”€â”€ attendapp/              â† repo aplikasi Laravel
    â”œâ”€â”€ app/  routes/  public/ ...
    â””â”€â”€ vendor/
```

> âš ï¸ Jika struktur ini tidak dipenuhi, Docker akan membuat folder kosong dan
> container akan gagal dengan `Composer could not find a composer.json file`.
>
> Bila Anda memakai struktur lain (mis. `attendapp/` di **dalam**
> `docker-ecosystem/`), timpa path-nya lewat file `app-laravel-docker/.env`:
>
> ```bash
> cd ~/projects/docker-ecosystem/app-laravel-docker
> echo 'LARAVEL_APP_PATH=../attendapp' > .env
> docker compose up -d --force-recreate app laravel-nginx
> ```

---

## ðŸ–¥ï¸ Panduan Lengkap Setup VPS Debian 12

> Semua perintah dijalankan via SSH sebagai user dengan hak `sudo`.
> Ganti `IP_VPS` dengan IP server Anda.

### 0) Masuk ke VPS

```bash
ssh user@IP_VPS
```

### 1) Update sistem & set timezone

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl git ca-certificates gnupg unzip

# Timezone (agar log & sertifikat tepat waktu)
sudo timedatectl set-timezone Asia/Jakarta
timedatectl
```

### 2) Install Docker Engine + Compose (cara resmi untuk Debian 12 "bookworm")

```bash
# 2.1 Tambahkan GPG key & repository resmi Docker
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian bookworm stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# 2.2 Install
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 2.3 Izinkan user non-root memakai docker
sudo usermod -aG docker $USER

# 2.4 Aktifkan saat boot
sudo systemctl enable --now docker
```

> **Penting:** setelah `usermod`, **logout lalu login ulang** (tutup sesi SSH dan
> sambung kembali) agar keanggotaan grup `docker` aktif.

Verifikasi:
```bash
docker --version            # Docker version xx.x.x
docker compose version      # Docker Compose version v2.x.x
docker run --rm hello-world # uji cepat
```

### 3) Firewall (UFW)

```bash
sudo apt install -y ufw
sudo ufw allow OpenSSH       # JANGAN dilewatkan, agar tidak terkunci dari SSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 9443/tcp      # Portainer
sudo ufw enable
sudo ufw status
```

> Port **5432 (PostgreSQL) sengaja TIDAK dibuka**. Akses database dari luar hanya
> lewat SSH tunnel (lihat bagian *pgAdmin*).

### 4) Install Portainer (GUI monitoring)

```bash
docker volume create portainer_data

docker run -d \
  --name portainer \
  --restart=always \
  -p 9443:9443 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  portainer/portainer-ce:latest

docker ps   # pastikan container "portainer" berstatus Up
```

Buka di browser: `https://IP_VPS:9443` â†’ buat akun admin â†’ pilih **Get Started (Local)**.

### 5) Clone repo dari GitHub

```bash
# Buat folder induk agar kedua repo bersebelahan
mkdir -p ~/projects && cd ~/projects

# 5.1 Repo infrastruktur (repo ini)
git clone https://github.com/samuelvittorior/docker-ecosystem.git

# 5.2 Repo aplikasi Laravel (harus bersebelahan!)
git clone https://github.com/samuelvittorior/attendapp.git

# Pastikan hasilnya:
ls -1
# docker-ecosystem
# attendapp
```

### 6) Siapkan file environment

File `.env.docker` sudah ikut ter-commit. **Wajib ganti password default!**

```bash
cd ~/projects/docker-ecosystem

nano db-postgres-docker/.env.docker
nano redis-shared-docker/.env.docker
nano app-laravel-docker/.env.docker
nano reverse-proxy-docker/.env.docker
```

| File | Variabel | Keterangan |
|------|----------|------------|
| `db-postgres-docker/.env.docker` | `POSTGRES_PASSWORD` | ganti dari `postgres` |
| `app-laravel-docker/.env.docker` | `DB_PASSWORD` | **harus sama** dengan di atas |
| `redis-shared-docker/.env.docker` | `REDIS_PASSWORD` | ganti dari default |
| `app-laravel-docker/.env.docker` | `REDIS_PASSWORD` | **harus sama** dengan di atas |
| `app-laravel-docker/.env.docker` | `REDIS_HOST` | `redis-shared` (jangan diubah) |
| `app-laravel-docker/.env.docker` | `REDIS_DB` / `REDIS_CACHE_DB` | nomor unik per aplikasi (lihat `redis-shared-docker/README.md`) |
| `app-laravel-docker/.env.docker` | `APP_URL` | sesuaikan domain Anda |
| `app-laravel-docker/.env.docker` | `APP_KEY` | **ganti & rahasiakan** (`php artisan key:generate --show`) |
| `app-laravel-docker/.env.docker` | `FPM_USER` / `FPM_GROUP` | biarkan `www-data` (user worker PHP-FPM) |

Verifikasi cepat bahwa repo aplikasi benar-benar ada di path yang dipakai volume:
```bash
ls -l ~/projects/docker-ecosystem/../../attendapp/composer.json
# harus ada file-nya. Jika "No such file", path volume Anda salah.
```

> ðŸ”‘ **Soal permission:** container `app` dijalankan sebagai **root**, lalu
> entrypoint otomatis `chown` folder `storage` & `bootstrap/cache` ke `www-data`
> dan menurunkan privilege worker PHP-FPM ke `www-data`. Karena itu Anda **tidak
> perlu** mencocokkan UID host dengan UID container.

Tambahkan juga file `.env` untuk Laravel (tidak ikut repo):
```bash
cd ~/projects/attendapp
cp .env.example .env
nano .env
#   APP_ENV=production
#   APP_DEBUG=false
#   APP_URL=http://app.attendapp.com
#   DB_CONNECTION=pgsql
#   DB_HOST=postgres-db
#   DB_PORT=5432
#   DB_DATABASE=attendapp
#   DB_USERNAME=postgres
#   DB_PASSWORD=<sama seperti .env.docker>
#   CACHE_DRIVER=redis
#   SESSION_DRIVER=redis
#   REDIS_CLIENT=phpredis
#   REDIS_HOST=redis-shared
#   REDIS_PASSWORD=<sama dengan redis-shared-docker/.env.docker>
#   REDIS_PORT=6379
```

> ⚠️ **Catatan penting (dependency PHP 8.2):** `composer.lock` repo ini sudah
> disesuaikan agar bisa dipasang di PHP 8.2 (image container memakai
> `php:8.2-fpm-alpine`). Karena itu **selalu** pakai `composer install`
> (bukan `composer update`) di server agar versi yang teruji ini yang dipakai.

### 7) Buat network bersama (WAJIB, sekali saja)

Ketiga compose memakai network `external: true` bernama `shared-network`,
sehingga harus dibuat manual **sebelum** `docker compose up`:

```bash
docker network create shared-network
docker network ls | grep shared-network
```

### 8) Jalankan stack berurutan

```bash
cd ~/projects/docker-ecosystem

cd db-postgres-docker && docker compose up -d && cd ..        # 8.1 database dulu
cd redis-shared-docker && docker compose up -d && cd ..      # 8.2 redis bersama
cd reverse-proxy-docker && docker compose up -d && cd ..     # 8.3 reverse proxy
cd app-laravel-docker && docker compose up -d --build && cd ..  # 8.4 aplikasi
```

Cek status & log:
```bash
docker ps
cd app-laravel-docker && docker compose logs -f app
```

Entrypoint container `app` otomatis menjalankan:
1. Membuat folder `storage/` & `bootstrap/cache/`
2. Memperbaiki permission kedua folder itu dengan `chown` ke `www-data`
   (**pengganti `chmod` manual**; container dijalankan sebagai root agar ini selalu bisa)
3. `composer install` (jika `vendor/` belum ada)
4. `php artisan storage:link`
5. **`php artisan optimize:clear`** — membuang cache lama SEBELUM apa pun di-cache.
   Wajib: `config:cache` **tidak** membaca ulang `.env` selama
   `bootstrap/cache/config.php` masih ada (lihat Troubleshooting)
6. `php artisan migrate --force` (jika `RUN_MIGRATIONS=true`)
7. `config:cache`, `route:cache`, `view:cache` (jika `RUN_OPTIMIZE=true`)
8. `chown` ulang `bootstrap/cache` (file cache baru ditulis sebagai root, sedangkan
   worker PHP-FPM berjalan sebagai `www-data`)
9. Self-check: container `app` menulis `config efektif -> redis.host=... cache=...`
   dan status `Redis: OK/GAGAL` + `Database: OK/GAGAL` ke log, jadi penyebab 500
   langsung terlihat di `docker compose logs app`

> Jika perlu menjalankan perintah manual di dalam container:
> ```bash
> docker compose exec app sh
> ```

### 9) Perbaikan permission (cadangan)

Entrypoint sudah menangani permission otomatis. Jika muncul error tulis
(mis. unggah foto gagal atau `mkdir ... Permission denied`), perbaiki sekali di host:

```bash
cd ~/projects/attendapp
sudo mkdir -p storage/framework/{cache/data,sessions,views} storage/logs bootstrap/cache
sudo chown -R www-data:www-data storage bootstrap/cache
sudo chmod -R 775 storage bootstrap/cache
```

> Jika container dijalankan dengan `user:` khusus (bukan root), ganti `www-data`
> sesuai user pada `FPM_USER`/`FPM_GROUP`.

### 10) DNS / pengujian domain

- **Produksi:** buat A record domain (`app.attendapp.com`) â†’ `IP_VPS`.
- **Uji cepat tanpa DNS:** sunting file `hosts` di komputer lokal, tambahkan
  `IP_VPS  app.attendapp.com`.
- **Belum punya domain sama sekali?** lanjut ke bagian **11** (akses lewat IP publik / `nip.io`).

Uji dari VPS:
```bash
curl -I http://localhost                                        # 200/302
curl -H "Host: app.attendapp.com" http://localhost/photos
```

### 11) Akses sementara TANPA domain (lewat IP publik)

Belum punya domain? Tidak masalah. Karena blok Laravel di `reverse-proxy-docker/nginx/default.conf`
diberi `default_server`, request yang datang lewat **IP publik** langsung diteruskan ke aplikasi.

**Cara 0 â€” paling cepat: port khusus tanpa domain (`:8101`)**

Reverse proxy sudah memetakan port host **8101** ke port 8080 container, dan
blok `listen 8080` di `reverse-proxy-docker/nginx/default.conf` meneruskan ke
`attendapp-nginx`. Jadi cukup:

```
http://IP_VPS:8101/
```

Blok ini memakai `proxy_set_header Host $http_host` (menyertakan port) supaya
URL yang di-generate Laravel (redirect, form action, aset) tetap memakai
`:8101` dan tidak "nyasar" ke port 80.

> Port host bisa diubah lewat variabel `APP_HTTP_PORT`. Karena Compose hanya
> membaca file `.env` untuk interpolasi (bukan `.env.docker`), caranya:
> `APP_HTTP_PORT=8101 docker compose up -d --force-recreate reverse-proxy`
> atau `docker compose --env-file .env.docker up -d --force-recreate reverse-proxy`.
> Jangan lupa buka port tersebut di firewall VPS:
> `sudo ufw allow 8101/tcp` (atau Security Group di cloud provider).

**Cara 1 â€” langsung lewat IP publik**

```bash
curl -4 ifconfig.me        # catat IP publik VPS
```

Buka di browser:
```
http://IP_VPS/
http://IP_VPS/photos
```

**Cara 2 (direkomendasikan) â€” pakai DNS wildcard gratis `nip.io`**

`nip.io` memetakan `<apa-saja>.<IP>.nip.io` ke `<IP>` **tanpa perlu daftar domain**,
sehingga routing berbasis `Host` (seperti nanti saat sudah punya domain) bisa diuji
persis. Contoh bila IP VPS `203.0.113.10`:
```
http://app.203.0.113.10.nip.io/
http://app.203.0.113.10.nip.io/photos
```
`sslip.io` bisa dipakai sebagai alternatif dengan pola yang sama.

Bentuk lain yang sering dipakai adalah IP dengan tanda hubung:
`http://app.203-0-113-10.nip.io/photos`.

**Cara 3 â€” lewatkan reverse proxy (khusus debugging)**

Untuk memastikan apakah masalahnya di aplikasi atau di reverse proxy, buka langsung
port Nginx internal aplikasi. Tambahkan sementara di `app-laravel-docker/docker-compose.yml`:

```yaml
  laravel-nginx:
    ports:
      - "8080:80"
```

```bash
cd ~/projects/docker-ecosystem/app-laravel-docker
docker compose up -d laravel-nginx
# akses: http://IP_VPS:8080
```

> Hapus kembali mapping `8080:80` setelah selesai (jangan dibiarkan di produksi).

**Prasyarat yang sering terlupa:**
```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw status
```

> Opsional: `APP_URL` di `app-laravel-docker/.env.docker` boleh dibiarkan.
> Asset & link Laravel mengikuti `Host` dari request, jadi tetap benar baik diakses
> lewat IP maupun `nip.io`. Set `APP_URL` permanen hanya saat domain final sudah siap.

---

## ðŸ” Akses Database lewat pgAdmin 4 (SSH Tunnel)

Port 5432 **tidak terbuka ke internet**, tetapi di-bind ke `127.0.0.1` di VPS
(lihat `db-postgres-docker/docker-compose.yml`) sehingga bisa dijangkau lewat SSH tunnel.

### âš ï¸ Sumber error "server closed the connection unexpectedly"

pgAdmin membuat tunnel seperti ini:

```
pgAdmin  â†’  sshd (VPS)  â†’  <Host>:<Port> yang Anda isi di tab Connection
```

Arti kolom di pgAdmin:

| Kolom | Diisi apa | Catatan |
|-------|-----------|---------|
| **SSH Tunnel â†’ Tunnel host** | `IP_VPS` | server SSH-nya |
| **SSH Tunnel â†’ Tunnel port** | `22` | port SSH |
| **Connection â†’ Host** | `127.0.0.1` | **alamat yang dilihat DARI DALAM VPS**, bukan dari laptop |
| **Connection â†’ Port** | `5432` | port PostgreSQL di dalam VPS |

Kesalahan paling umum: mengisi **Connection â†’ Host** dengan `127.0.0.1` **tanpa**
mengaktifkan SSH tunnel. Akibatnya pgAdmin mencoba `127.0.0.1:5432` di **laptop Anda
sendiri** (bukan VPS) â†’ tidak ada PostgreSQL di sana â†’ koneksi ditutup.

Kesalahan kedua: mengisi **Connection â†’ Host** dengan `postgres-db` atau
`IP_VPS`. Nama container tidak bisa di-resolve oleh `sshd` di host, dan port
5432 tidak terbuka ke publik â€” dua-duanya gagal.

### Cara A â€” SSH Tunnel dari dalam pgAdmin 4

1. Pastikan port sudah di-bind di VPS (sekali saja):
   ```bash
   cd ~/projects/docker-ecosystem/db-postgres-docker
   docker compose up -d --force-recreate postgres
   sudo ss -tlnp | grep 5432      # harus muncul 127.0.0.1:5432
   ```
2. Di pgAdmin: klik kanan *Servers* â†’ **Register** â†’ **Serverâ€¦**
3. Tab **General**: Name = `VPS Laravel`
4. Tab **Connection**:
   - Host = `127.0.0.1`
   - Port = `5432`
   - Maintenance database = `attendapp`
   - Username = `postgres`, Password = password DB Anda
5. Tab **SSH Tunnel**: centang **Use SSH tunneling**
   - Tunnel host = `IP_VPS`
   - Tunnel port = `22`
   - Username = user SSH VPS Anda
   - Authentication = *Password* atau *Identity file* (private key)
6. **Save** â†’ pgAdmin membuat tunnel otomatis.

### Cara B â€” tunnel manual via terminal (paling mudah didiagnosis)

```bash
ssh -N -L 5432:127.0.0.1:5432 user@IP_VPS
```
Biarkan terminal itu terbuka, lalu di pgAdmin **matikan** SSH Tunnel dan isi:
Host = `127.0.0.1`, Port = `5432`.

Jika cara ini berhasil tetapi Cara A gagal, berarti masalahnya di kredensial/key
pada tab SSH Tunnel (bukan di PostgreSQL).

### Verifikasi cepat di VPS

```bash
# 1) port benar-benar listen di loopback
sudo ss -tlnp | grep 5432

# 2) login langsung dari dalam VPS
docker compose -f ~/projects/docker-ecosystem/db-postgres-docker/docker-compose.yml \
  exec postgres psql -U postgres -d attendapp -c '\dt'

# 3) cek log container bila koneksi ditolak
docker logs --tail=50 postgres-db
```

> â— Jangan pernah memakai `ports: "5432:5432"` (tanpa `127.0.0.1:`). Itu membuka
> database ke seluruh internet. Binding loopback + SSH tunnel sudah cukup aman.


---

## âš™ï¸ GitHub Actions (Auto Deploy)

| Repo | File workflow | Fungsi |
|------|---------------|--------|
| `docker-ecosystem` | `.github/workflows/deploy-infra.yml` | Validasi compose + deploy infra ke VPS |
| `attendapp` | `.github/workflows/deploy.yml` | Test (PHPUnit) + deploy aplikasi (rebuild, migrate, cache) |

> âš ï¸ GitHub **hanya** membaca workflow dari `.github/workflows/` di **root repo**.
> Workflow di subfolder (mis. `app-laravel-docker/.github/...`) tidak akan dijalankan.

### Secrets di GitHub (isi di KEDUA repo)

Repo â†’ **Settings** â†’ **Secrets and variables** â†’ **Actions** â†’ **New repository secret**:

| Secret | Contoh | Keterangan |
|--------|--------|------------|
| `VPS_HOST` | `203.0.113.10` | IP/hostname VPS |
| `VPS_USER` | `deployer` | user SSH untuk deploy |
| `VPS_SSH_KEY` | `-----BEGIN OPENSSH PRIVATE KEY-----â€¦` | **private key** SSH |
| `VPS_PORT` | `22` | port SSH |
| `VPS_INFRA_PATH` | `/home/deployer/projects/docker-ecosystem` | path repo infra di VPS |
| `VPS_APP_PATH` | `/home/deployer/projects/attendapp` | path repo app (khusus repo Laravel) |

### Membuat SSH key khusus deploy

```bash
ssh-keygen -t ed25519 -C "github-actions-deploy" -f ~/.ssh/deploy_key -N ""
ssh-copy-id -i ~/.ssh/deploy_key.pub user@IP_VPS
cat ~/.ssh/deploy_key      # salin seluruh isi ini ke secret VPS_SSH_KEY
```

---

## ðŸ§° Cheatsheet Pemeliharaan

```bash
docker ps -a                                    # status semua container

cd ~/projects/docker-ecosystem/app-laravel-docker
docker compose logs -f app                      # log aplikasi
docker compose logs -f laravel-nginx
docker compose restart app                      # restart app
docker compose exec app sh                      # masuk shell

docker compose exec app php artisan migrate --force
docker compose exec app php artisan config:clear && php artisan cache:clear
docker compose up -d --build app laravel-nginx  # rebuild setelah ubah Dockerfile

docker image prune -f                           # bersihkan image lama
docker system df
```

---

## âš¡ Optimasi Performa (gzip, HTTP/2, HTTPS, cache)

Halaman Laravel ini memuat **ratusan file JS/CSS (>14 MB mentah)**. Yang membuatnya
terasa cepat di shared hosting biasanya bukan PHP-nya, melainkan 4 hal di bawah ini â€”
dan semuanya sudah disiapkan di repo ini:

| # | Hal | Status di repo | Dampak |
|---|---|---|---|
| 1 | **Kompresi gzip** | aktif di `app-laravel-docker/nginx/default.conf` **dan** `reverse-proxy-docker/nginx/default.conf` | JS/CSS/HTML mengecil 65â€“80% |
| 2 | **Cache aset 30 hari** | `Cache-Control: public, max-age=2592000, immutable` | kunjungan berikutnya tidak mengunduh ulang |
| 3 | **HTTPS + HTTP/2** | template `nginx/extra/attendapp-ssl.conf.example` + `tools/enable-https.sh` | aset diunduh paralel (multiplexing), bukan berderet |
| 4 | **Cache produksi Laravel** | `RUN_OPTIMIZE=true` di `.env.docker` (config/route/view cache) | config & Blade tidak di-parse ulang tiap request |

> **Catatan penting:** direktif `no-transform` pada header `Cache-Control` aset
> **dihapus**. Direktif itu melarang proxy/CDN mengubah respons â€” termasuk
> mengompresinya â€” sehingga kompresi otomatis Cloudflare pun ikut mati.

### 1) Cek apakah gzip benar-benar aktif

```bash
curl -sI -H 'Accept-Encoding: gzip' http://127.0.0.1:8101/form/css/style.css | grep -i content-encoding
# harus muncul: content-encoding: gzip
```

Kalau tidak muncul, config nginx belum dimuat â€” nginx **tidak** reload otomatis
untuk file yang di-bind-mount:

```bash
cd reverse-proxy-docker && docker compose up -d --force-recreate
cd ../app-laravel-docker && docker compose up -d --force-recreate laravel-nginx
```

### 2) Mengaktifkan HTTPS + HTTP/2 (Let's Encrypt)

Prasyarat: domain sudah mengarah (A record) ke IP VPS, port 80/443 terbuka, dan
`certbot` terpasang (`sudo apt-get install -y certbot`).

```bash
cd ~/projects/docker-ecosystem
bash tools/enable-https.sh app.attendapp.com admin@attendapp.com
```

Skrip ini: menghentikan proxy sementara â†’ meminta sertifikat â†’ menyalin ke
`reverse-proxy-docker/nginx/certs/` â†’ menulis
`reverse-proxy-docker/nginx/extra/attendapp-ssl.conf` (blok 443 + redirect
httpâ†’https + `http2 on`) â†’ menjalankan ulang proxy â†’ menguji hasilnya.

Setelah HTTPS berjalan, ubah di **dua** tempat:

```ini
# attendapp/.env  dan  app-laravel-docker/.env.docker
APP_URL=https://app.attendapp.com
APP_FORCE_HTTPS=true
```

```bash
cd app-laravel-docker && docker compose up -d --force-recreate app
```

> Blok SSL **sengaja dipisah** ke folder `nginx/extra/`. Kalau blok 443 ditulis
> langsung di `default.conf` sebelum sertifikat ada, nginx gagal start
> (`cannot load certificate`) dan **semua** domain di proxy ikut mati.
> File `*.example` tidak pernah dimuat nginx.

---


### 3) Memastikan cache produksi Laravel benar-benar dibuat

```bash
docker exec attendapp-app ls -la /var/www/html/bootstrap/cache/
# harus ada: config.php  dan  routes-v7.php
docker exec attendapp-app ls /var/www/html/storage/framework/views | wc -l
# harus > 0
```

Kalau kosong: pastikan `RUN_OPTIMIZE=true` di `app-laravel-docker/.env.docker`,
lalu `docker compose up -d --force-recreate app`.

### 4) Menyesuaikan PostgreSQL dengan RAM VPS

Setelan memori PostgreSQL **tidak boleh** lebih besar dari RAM VPS. Cek RAM lalu
pilih profil di `db-postgres-docker/.env.docker`:

```bash
free -h    # mis. total 4 GB -> POSTGRES_TUNING=medium
```

| `POSTGRES_TUNING` | RAM VPS | shared_buffers | work_mem | max_connections |
|---|---|---|---|---|
| `small` | 1â€“2 GB | 256 MB | 8 MB | 30 |
| `medium` | 4 GB | 1024 MB | 16 MB | 50 |
| `large` (default) | 6â€“8 GB | 1536 MB | 32 MB | 100 |
| `custom` | bebas | dari `POSTGRES_TUNING_*` | | |

> `shared-buffer.sql` hanya dijalankan **saat volume `postgres-data` masih
> kosong**. Untuk menerapkan ke database yang sudah ada, jalankan isi file itu
> lewat psql:
> ```bash
> docker exec -i postgres-db psql -U postgres -d attendapp \
>   < db-postgres-docker/postgres/conf.d/shared-buffer.sql
> docker restart postgres-db        # shared_buffers butuh restart, bukan reload
> ```

### 5) Ukur, jangan menebak

```bash
cd ~/projects/docker-ecosystem
bash tools/perf-check.sh
```

Skrip ini mencetak: pemakaian RAM/swap, `docker stats`, hasil tes gzip, **TTFB
dari dalam VPS** (memisahkan masalah aplikasi vs jaringan), status cache
config/route/view, OPcache, setelan PostgreSQL, dan memori Redis.

Cara membaca hasilnya:

- **TTFB dari dalam VPS kecil (<300 ms)** tetapi dari laptop terasa lambat â†’
  masalah **jaringan/aset**: pasang CDN (Cloudflare) + aktifkan HTTP/2, atau
  pertimbangkan VPS region Singapura/Jakarta.
- **TTFB dari dalam VPS besar (>800 ms)** â†’ masalah **aplikasi/DB**: cek poin 3
  dan 4 di atas.
- **Swap terpakai > 0** â†’ RAM kurang: turunkan `POSTGRES_TUNING`.

---


## 🛠 Tools Bantu (opsional)

Dua skrip di `tools/` untuk mempermudah operasional di VPS:

| Skrip | Fungsi |
|---|---|
| `tools/diagnose.sh` | **Read-only.** 16 pemeriksaan: status container, port, anggota `shared-network`, config nginx yang benar-benar dimuat (`nginx -T`), tes DNS & HTTP berlapis, cek PHP-FPM, tail log. Jalankan saat ada 502. |
| `tools/reset-stack.sh` | Membersihkan container sisa bernama lama, recreate reverse proxy, build & jalankan stack aplikasi, lalu verifikasi DNS + HTTP. **Tidak** menghapus volume data. |
| `tools/perf-check.sh` | **Read-only.** Cek penyebab lambat dengan angka: RAM/swap, `docker stats`, apakah gzip aktif, **TTFB dari dalam VPS**, cache config/route/view, OPcache, setelan PostgreSQL, memori Redis. |
| `tools/enable-https.sh` | Mengaktifkan **HTTPS + HTTP/2** (Let's Encrypt): buat sertifikat â†’ salin ke `nginx/certs/` â†’ tulis `nginx/extra/attendapp-ssl.conf` â†’ recreate proxy â†’ uji. Idempoten (aman dijalankan ulang untuk perpanjangan). |

```bash
cd ~/projects/docker-ecosystem
bash tools/diagnose.sh      # kalau ada masalah (502, 404, dll)
bash tools/perf-check.sh    # kalau terasa lambat
bash tools/reset-stack.sh   # kalau perlu bersih-bersih & jalan ulang
bash tools/enable-https.sh app.attendapp.com admin@attendapp.com   # aktifkan HTTPS
```

> **Penting — nama service ≠ nama DNS.** Nama yang bisa di-resolve antar
> container hanyalah **nama service Compose** atau **`aliases`** pada network,
> **bukan** `container_name`. Itulah sebabnya
> `app-laravel-docker/docker-compose.yml` mendaftarkan
> `aliases: [attendapp-nginx, laravel-nginx]` (untuk nginx) dan
> `aliases: [app, attendapp-app, app-fpm]` (untuk PHP-FPM).

---


## ðŸ©º Troubleshooting

| Gejala | Sebab | Solusi |
|--------|-------|--------|
| `network shared-network not found` | network belum dibuat | `docker network create shared-network` lalu `docker compose up -d` ulang |
| 502 Bad Gateway | `attendapp-nginx` / `app` mati | `docker compose ps` & `docker compose logs laravel-nginx` |
| **`502` + log `==> vendor/ belum ada, menjalankan composer install...` berulang** | `composer install` gagal → entrypoint `exit 1` → Docker restart-loop → `app` tidak pernah listen di `:9000` → nginx balas 502 | cek pesan Composer di `docker compose logs app`; penyebab tersering `composer.lock` tidak kompatibel dengan PHP container (lihat baris berikut) |
| **`nette/schema v1.2.2 requires php >=7.1 <8.2 -> your php version (8.2.35) does not satisfy that requirement`** | lock lama (dependensi transitif `league/config`) dibatasi PHP < 8.2, sedangkan image memakai PHP 8.2 | sudah diperbaiki: `nette/schema` dinaikkan ke v1.4.0 (`php 8.1 - 8.6`), `nette/utils` v4.0.11, `league/config` v1.2.0. Terapkan dengan `git pull` di repo aplikasi lalu `docker compose up -d --build app`. Bila memakai lock sendiri: `composer update nette/schema league/config --with-dependencies` |
| **`fatal: detected dubious ownership in repository at '/var/www/html'`** | folder aplikasi di-bind-mount dan dimiliki user host, sedangkan proses container berjalan sebagai `root` | sudah diperbaiki: entrypoint menjalankan `git config --global --add safe.directory /var/www/html`. Manual: `docker compose exec app git config --global --add safe.directory /var/www/html` |
| **`!! Redis belum siap setelah 30 detik` padahal Redis hidup** | pengecekan lama memakai `echo > /dev/tcp/...` yang merupakan fitur **bash**, sedangkan `/bin/sh` di Alpine = BusyBox ash | sudah diperbaiki: entrypoint memakai `php -r` + `fsockopen`. Pastikan juga `REDIS_HOST=redis-shared` & `REDIS_PORT=6379` |
| **`RedisException: NOAUTH Authentication required` (muncul di `PhpRedisConnector.php`)** | (a) `REDIS_PASSWORD` aplikasi beda/kosong, sedangkan Redis bersama memakai `requirepass`; ATAU (b) **`bootstrap/cache/config.php` basi** yang masih menyimpan password/host Redis LAMA | samakan `REDIS_PASSWORD` di `app-laravel-docker/.env.docker` dengan `redis-shared-docker/.env.docker`, lalu `docker compose up -d --build --force-recreate app` (entrypoint terbaru otomatis `optimize:clear` lebih dulu). Verifikasi: `bash tools/why-500.sh` bagian 7 |
| **`config:cache` seolah tidak berpengaruh: `redis.host` tetap `redis` padahal `.env.docker` sudah `redis-shared`** | **`bootstrap/cache/config.php` basi.** Laravel memakai file itu bila ada dan **melewati `.env` seluruhnya** (`LoadConfiguration`: `if (file_exists($cached)) { $items = require $cached; $loadedFromCache = true; }`). File basi bertahan bila `RUN_OPTIMIZE` bukan `true`, bila dibuat di mesin lain lalu folder aplikasi di-copy (`bootstrap/cache/*.php` ada di `.gitignore` aplikasi, jadi `git pull` tidak menghapusnya), atau bila langkah pembuat cache gagal | entrypoint terbaru **selalu** menghapus cache basi saat container start (termasuk `config.php` & `routes-v7.php` dipaksa `rm` bila `optimize:clear` gagal) -> cukup `docker compose up -d --build --force-recreate app`. Deteksi: `bash tools/why-500.sh` bagian 7 membandingkan isi `config.php` dengan environment lalu menuliskan diagnosanya |
| **`The only supported ciphers are AES-128-CBC and AES-256-CBC with the correct key lengths`** | `APP_KEY` salah panjang. Laravel butuh **tepat 32 byte** (`base64:` + 32 byte) atau 32 karakter mentah; placeholder seperti `SI_SECRET_APIKEY_XXXX` (25 karakter) SELALU gagal dan membuat semua request 500 | buat kunci asli: `docker compose exec app php artisan key:generate --show`, lalu isikan ke `app-laravel-docker/.env.docker`. Bila di VPS `.env.docker` pernah diedit manual, kembalikan versi repo: `git checkout -- app-laravel-docker/.env.docker`. Setelah itu `docker compose up -d --build --force-recreate app` |
| **`TypeError: RouteCacheCommand::buildRouteCacheFile(): Argument #1 ($routes) must be of type RouteCollection, CompiledRouteCollection given`** | `php artisan route:cache` dijalankan sementara `bootstrap/cache/routes-v7.php` lama masih ada, sehingga rute yang sudah ter-cache dimuat ulang | entrypoint terbaru menjalankan `optimize:clear` lebih dulu. Manual: `docker exec attendapp-app sh -c "cd /var/www/html && rm -f bootstrap/cache/routes-v7.php"` lalu `php artisan route:cache` |
| **`php artisan tinker` menampilkan nilai berbeda dari `.env.docker` (mis. `redis.host`, `app.key`)** | cache config basi (baris di atas) atau file `.env` aplikasi berisi nilai lain. `.env` diabaikan untuk kunci yang sudah diisi environment container, jadi yang menang bisa berbeda antar konteks | samakan nilai penting (khususnya `APP_KEY`) antara `attendapp/.env` dan `app-laravel-docker/.env.docker`, lalu hapus cache lama. Periksa dengan `bash tools/why-500.sh` bagian 2 dan 7 |
| **Halaman web 500 (DB/Redis gagal) padahal `docker exec app php artisan tinker` melaporkan DB & Redis OK** | PHP-FPM membuang environment container. Default `clear_env = yes` membuat worker HTTP **tidak** menerima `env_file`/`environment:` dari compose, sehingga Laravel jatuh ke `attendapp/.env` (nilai lokal `127.0.0.1`), sementara CLI tetap memakai environment container | sudah diperbaiki: `app-laravel-docker/php/www.conf` memuat `clear_env = no`. Terapkan dengan `docker compose up -d --build --force-recreate app` (file `www.conf` di-COPY ke image, jadi rebuild wajib). Periksa: `bash tools/why-500.sh` bagian 10 |
| **`Could not connect to Redis at redis-shared:6379`** | container `redis-shared` belum jalan, atau service app tidak ikut `shared-network` | `cd redis-shared-docker && docker compose up -d`; cek `docker network inspect shared-network` (harus memuat `redis-shared` dan `attendapp-app`) |
| **Cache aplikasi lain hilang setelah `cache:clear`** | nomor `REDIS_DB` / `REDIS_CACHE_DB` bertabrakan antar aplikasi | beri nomor unik per aplikasi (tabel alokasi di `redis-shared-docker/README.md`) |
| **`OOM command not allowed when used memory > maxmemory`** | policy `noeviction` + memori Redis penuh | naikkan `REDIS_MAXMEMORY` di `redis-shared-docker/.env.docker`, lalu `docker compose up -d --force-recreate redis` |
| "Class not found" | `vendor/` belum ada | `docker compose exec app composer install --no-dev -o` |
| **`mkdir ... Permission denied` + container restart terus** | UID container â‰  owner folder di host | perbaiki file compose/entrypoint terbaru (container jalan sebagai root + `chown www-data`), lalu `docker compose up -d --build app`. Sementara: `sudo chown -R www-data:www-data storage bootstrap/cache` |
| **`Composer could not find a composer.json file` / `/var/www/html` kosong** | path volume salah â†’ Docker membuat folder kosong | cek `LARAVEL_APP_PATH`; default harus `../../attendapp` (sibling repo), bukan `../attendapp` |
| **`No application encryption key has been specified`** | `APP_KEY` belum di-set | isi `APP_KEY` di `app-laravel-docker/.env.docker`, lalu recreate container |
| **`http://IP_VPS/` menampilkan "Reverse Proxy is running..."** | blok catch-all masih `default_server` | beri `default_server` ke blok Laravel di `reverse-proxy-docker/nginx/default.conf`, lalu `docker compose up -d --force-recreate reverse-proxy` |
| **`nginx: [emerg] host not found in upstream "attendapp-nginx"` + reverse proxy restart terus** | nginx me-resolve nama upstream **saat start**; container `attendapp-nginx` belum/tidak berjalan | sudah diperbaiki: `default.conf` memakai `resolver 127.0.0.11` + `proxy_pass` variabel (`$attendapp_upstream`) sehingga DNS baru di-resolve saat request. Terapkan dengan `docker compose up -d --force-recreate reverse-proxy` |
| **`attendapp-nginx could not be resolved (3: Host not found)` + 502** | (a) container `attendapp-nginx` tidak berjalan / tidak ikut `shared-network`, atau (b) sisa container bernama lama masih ada & stack belum di-recreate setelah service di-rename | jalankan `bash tools/reset-stack.sh` (membersihkan container lama + recreate berurutan + cek DNS). Pastikan `app-laravel-docker/docker-compose.yml` memuat `aliases: [attendapp-nginx]` pada `shared-network` |
| **`http://IP_VPS:8101` tidak bisa dibuka / connection refused** | port belum dipetakan, firewall menutup, atau container lama belum di-recreate | pastikan `ports:` berisi `"${APP_HTTP_PORT:-8101}:8080"`, lalu `docker compose up -d --force-recreate reverse-proxy`; buka firewall `sudo ufw allow 8101/tcp`; cek `ss -tlnp \| grep 8101` |
| Perubahan konfigurasi Nginx tidak berlaku | container belum di-recreate | `docker compose up -d --force-recreate <service>` (nginx tidak reload otomatis) |
| **Aplikasi terasa lambat, padahal `php artisan` cepat** | gzip/HTTP2 belum aktif, atau aset tidak ter-cache, atau latency datacenter | jalankan `bash tools/perf-check.sh`. Bila TTFB dari dalam VPS kecil (<300 ms) tetapi dari browser lambat -> masalah jaringan/aset: aktifkan HTTP/2 (`tools/enable-https.sh`) dan/atau pasang CDN |
| **Aset `.css`/`.js` terkirim ukuran penuh (tidak terkompresi)** | container nginx belum di-recreate setelah `gzip` ditambahkan; atau CDN memblokir karena header `no-transform` | `docker compose up -d --force-recreate` di `app-laravel-docker` dan `reverse-proxy-docker`; cek `curl -sI -H 'Accept-Encoding: gzip' http://127.0.0.1:8101/form/css/style.css \| grep -i content-encoding` |
| **`nginx: [emerg] cannot load certificate`** setelah mengaktifkan HTTPS | file `.crt`/`.key` tidak ada di `reverse-proxy-docker/nginx/certs/` | jalankan `bash tools/enable-https.sh <domain> <email>`; bila sertifikat sudah tidak dipakai, hapus `nginx/extra/attendapp-ssl.conf` lalu recreate proxy |
| **VPS terasa lambat + `swap` terpakai** | `POSTGRES_TUNING` terlalu besar untuk RAM VPS | turunkan profil di `db-postgres-docker/.env.docker` (`large` -> `medium`/`small`), lalu terapkan lewat psql + `docker restart postgres-db` |
| `nginx: [emerg] a duplicate default server for 0.0.0.0:80` | ada 2 blok `default_server` di port 80 | pastikan hanya **satu** blok yang memakai `default_server` |
| **pgAdmin: `connection to server at "127.0.0.1", port ... failed: server closed the connection unexpectedly`** | (a) SSH Tunnel tidak dicentang, atau (b) port 5432 belum di-bind ke `127.0.0.1` di VPS | centang *Use SSH tunneling* + isi Tunnel host = IP VPS; lalu di VPS `docker compose up -d --force-recreate postgres` dan cek `ss -tlnp \| grep 5432` |
| **pgAdmin: `could not translate host name "postgres-db"`** | Connection â†’ Host diisi nama container, padahal tunnel keluar di host VPS | ganti Connection â†’ Host menjadi `127.0.0.1` |
| Unggah foto gagal (permission) | owner `storage` tidak sesuai | `sudo chown -R www-data:www-data storage bootstrap/cache` |
| `route:cache` gagal | route berbasis Closure | pakai `Route::view('/', 'welcome')` |
| DB connection refused | app & db beda network, DB belum siap | pastikan keduanya di `shared-network`, cek log `postgres-db` |
| Port 80 sudah dipakai | Apache/Nginx di host aktif | `sudo systemctl stop apache2 nginx` |

---

## ðŸ“Œ Catatan

- **Keamanan:** `.env.docker` ikut ter-commit dan berisi kredensial â€” **ganti password**
  sebelum online. Jika repo publik, pertimbangkan memakai `.env.docker.example`.
- **PostgreSQL** di-bind ke `127.0.0.1:5432` (loopback saja). Jangan diganti menjadi
  `5432:5432` karena itu membuka database ke internet. Akses dari luar memakai SSH tunnel.
- **Kustomisasi RAM:** profil memori PostgreSQL diatur lewat **satu baris**
  `POSTGRES_TUNING` (`small|medium|large|custom`) di `db-postgres-docker/.env.docker`,
  yang dibaca oleh `db-postgres-docker/postgres/conf.d/shared-buffer.sql`.
  Default `large` = VPS Â±6 GB (shared_buffers 1536 MB, work_mem 32 MB).
- **HTTPS:** blok SSL **dipisah** ke `reverse-proxy-docker/nginx/extra/` (template
  `attendapp-ssl.conf.example`) supaya `default.conf` tetap valid sebelum
  sertifikat ada. Aktifkan dengan `bash tools/enable-https.sh <domain> <email>`
  (lihat bagian **Optimasi Performa**).
- **Kompresi gzip** aktif di kedua nginx. Jika aset masih terkirim mentah,
  container belum di-recreate (`nginx` tidak reload otomatis untuk file yang
  di-bind-mount).
- **Penting saat update kode aplikasi:** `git pull` di VPS tidak menghapus `vendor/`
  yang isinya tidak lengkap/korup (vendor di-`.gitignore`). Bila `vendor/autoload.php`
  ada padahal paketnya tidak lengkap, entrypoint menganggap instalasi sudah selesai.
  Bersihkan sekali dengan:
  ```bash
  cd ~/projects/attendapp && rm -rf vendor
  cd ~/projects/docker-ecosystem/app-laravel-docker && docker compose up -d --force-recreate app
  ```



