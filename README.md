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
                            â”‚
                            â–¼
              â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
              â”‚  reverse-proxy (nginx:alpine)â”‚  port 80 / 443
              â”‚  app.attendapp.com        â”‚
              â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
                             â”‚ proxy_pass (HTTP) via shared-network
                             â–¼
              â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
              â”‚ laravel-nginx (nginx:alpine)â”‚  listen 80
              â”‚ root: /var/www/html/public  â”‚
              â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
                             â”‚ fastcgi_pass app:9000
                             â–¼
              â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
              â”‚ app (php:8.2-fpm)          â”‚
              â”‚  /var/www/html â† $LARAVEL_APP_PATH
              â””â”€â”€â”€â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”€â”˜
                      â”‚              â”‚
        shared-networkâ”‚              â”‚laravel-network
                      â–¼              â–¼
        â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”  â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
        â”‚ postgres-db       â”‚  â”‚ redis        â”‚
        â”‚ postgres:15-alpineâ”‚  â”‚ redis:alpine â”‚
        â”‚ (port TIDAK dibuka)â”‚ â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
        â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
```

**Peran tiap folder:**

| Folder | Isi | Port |
|--------|-----|------|
| `app-laravel-docker/` | PHP-FPM (Laravel) + Nginx internal + Redis | internal (9000, 80) |
| `db-postgres-docker/` | PostgreSQL 15 (dibuat pertama, membuat `shared-network`) | tidak diekspos |
| `reverse-proxy-docker/` | Nginx reverse proxy subdomain | 80, 443 |

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
nano app-laravel-docker/.env.docker
nano reverse-proxy-docker/.env.docker
```

| File | Variabel | Keterangan |
|------|----------|------------|
| `db-postgres-docker/.env.docker` | `POSTGRES_PASSWORD` | ganti dari `postgres` |
| `app-laravel-docker/.env.docker` | `DB_PASSWORD` | **harus sama** dengan di atas |
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
#   REDIS_HOST=redis
#   REDIS_PORT=6379
```

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
cd reverse-proxy-docker && docker compose up -d && cd ..     # 8.2 reverse proxy
cd app-laravel-docker && docker compose up -d --build && cd ..  # 8.3 aplikasi
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
5. `php artisan migrate --force` (jika `RUN_MIGRATIONS=true`)
6. `config:cache`, `route:cache`, `view:cache` (jika `RUN_OPTIMIZE=true`)

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

## ðŸ©º Troubleshooting

| Gejala | Sebab | Solusi |
|--------|-------|--------|
| `network shared-network not found` | network belum dibuat | `docker network create shared-network` lalu `docker compose up -d` ulang |
| 502 Bad Gateway | `laravel-nginx` / `app` mati | `docker compose ps` & `docker compose logs laravel-nginx` |
| "Class not found" | `vendor/` belum ada | `docker compose exec app composer install --no-dev -o` |
| **`mkdir ... Permission denied` + container restart terus** | UID container â‰  owner folder di host | perbaiki file compose/entrypoint terbaru (container jalan sebagai root + `chown www-data`), lalu `docker compose up -d --build app`. Sementara: `sudo chown -R www-data:www-data storage bootstrap/cache` |
| **`Composer could not find a composer.json file` / `/var/www/html` kosong** | path volume salah â†’ Docker membuat folder kosong | cek `LARAVEL_APP_PATH`; default harus `../../attendapp` (sibling repo), bukan `../attendapp` |
| **`No application encryption key has been specified`** | `APP_KEY` belum di-set | isi `APP_KEY` di `app-laravel-docker/.env.docker`, lalu recreate container |
| **`http://IP_VPS/` menampilkan "Reverse Proxy is running..."** | blok catch-all masih `default_server` | beri `default_server` ke blok Laravel di `reverse-proxy-docker/nginx/default.conf`, lalu `docker compose up -d --force-recreate reverse-proxy` |
| Perubahan konfigurasi Nginx tidak berlaku | container belum di-recreate | `docker compose up -d --force-recreate <service>` (nginx tidak reload otomatis) |
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
- **Kustomisasi RAM:** nilai di `db-postgres-docker/postgres/conf.d/shared-buffer.sql`
  dioptimalkan untuk VPS Â±6 GB. Sesuaikan bila berbeda.
- **HTTPS:** blok SSL di `reverse-proxy-docker/nginx/default.conf` masih dikomentari.
  Aktifkan setelah punya sertifikat (mis. Let's Encrypt/Certbot).



