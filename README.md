# 🐳 Docker Ecosystem — Laravel + PostgreSQL + Redis + Nginx Reverse Proxy

Kumpulan **Docker Compose** yang terpisah namun saling terhubung lewat satu network
bersama (`shared-network`), dirancang untuk VPS kecil (RAM ±6 GB) dan mudah di-scale
ke banyak aplikasi Laravel.

> Kode aplikasi Laravel **tidak** disimpan di repo ini. Repo ini hanya berisi
> konfigurasi infrastruktur. Kode aplikasi ada di repo terpisah (`laravel-test`),
> dan di-mount ke container melalui volume `${LARAVEL_APP_PATH:-../../laravel-test}`.

---

## 🏗️ Arsitektur

```
                        Internet
                            │
                            ▼
              ┌─────────────────────────────┐
              │  reverse-proxy (nginx:alpine)│  port 80 / 443
              │  app.laravel-test.com        │
              └───────────────┬─────────────┘
                             │ proxy_pass (HTTP) via shared-network
                             ▼
              ┌─────────────────────────────┐
              │ laravel-nginx (nginx:alpine)│  listen 80
              │ root: /var/www/html/public  │
              └──────────────┬──────────────┘
                             │ fastcgi_pass laravel-app:9000
                             ▼
              ┌─────────────────────────────┐
              │ laravel-app (php:8.2-fpm)   │
              │  /var/www/html ← $LARAVEL_APP_PATH
              └───────┬──────────────┬──────┘
                      │              │
        shared-network│              │laravel-network
                      ▼              ▼
        ┌───────────────────┐  ┌──────────────┐
        │ postgres-db       │  │ redis        │
        │ postgres:15-alpine│  │ redis:alpine │
        │ (port TIDAK dibuka)│ └──────────────┘
        └───────────────────┘
```

**Peran tiap folder:**

| Folder | Isi | Port |
|--------|-----|------|
| `app-laravel-docker/` | PHP-FPM (Laravel) + Nginx internal + Redis | internal (9000, 80) |
| `db-postgres-docker/` | PostgreSQL 15 (dibuat pertama, membuat `shared-network`) | tidak diekspos |
| `reverse-proxy-docker/` | Nginx reverse proxy subdomain | 80, 443 |

---

## 📁 Struktur Direktori yang Diharapkan di VPS

Kedua repo harus berada pada **folder induk yang sama** karena volume memakai
path relatif `${LARAVEL_APP_PATH:-../../laravel-test}` (dihitung dari folder
`app-laravel-docker/`):

```
~/projects/
├── docker-ecosystem/          ← repo ini
│   ├── app-laravel-docker/
│   ├── db-postgres-docker/
│   └── reverse-proxy-docker/
└── laravel-test/              ← repo aplikasi Laravel
    ├── app/  routes/  public/ ...
    └── vendor/
```

> ⚠️ Jika struktur ini tidak dipenuhi, Docker akan membuat folder kosong dan
> container akan gagal dengan `Composer could not find a composer.json file`.
>
> Bila Anda memakai struktur lain (mis. `laravel-test/` di **dalam**
> `docker-ecosystem/`), timpa path-nya lewat file `app-laravel-docker/.env`:
>
> ```bash
> cd ~/projects/docker-ecosystem/app-laravel-docker
> echo 'LARAVEL_APP_PATH=../laravel-test' > .env
> docker compose up -d --force-recreate app laravel-nginx
> ```

---

## 🖥️ Panduan Lengkap Setup VPS Debian 12

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

Buka di browser: `https://IP_VPS:9443` → buat akun admin → pilih **Get Started (Local)**.

### 5) Clone repo dari GitHub

```bash
# Buat folder induk agar kedua repo bersebelahan
mkdir -p ~/projects && cd ~/projects

# 5.1 Repo infrastruktur (repo ini)
git clone https://github.com/samuelvittorior/docker-ecosystem.git

# 5.2 Repo aplikasi Laravel (harus bersebelahan!)
git clone https://github.com/samuelvittorior/laravel-test.git

# Pastikan hasilnya:
ls -1
# docker-ecosystem
# laravel-test
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
ls -l ~/projects/docker-ecosystem/../../laravel-test/composer.json
# harus ada file-nya. Jika "No such file", path volume Anda salah.
```

> 🔑 **Soal permission:** container `laravel-app` dijalankan sebagai **root**, lalu
> entrypoint otomatis `chown` folder `storage` & `bootstrap/cache` ke `www-data`
> dan menurunkan privilege worker PHP-FPM ke `www-data`. Karena itu Anda **tidak
> perlu** mencocokkan UID host dengan UID container.

Tambahkan juga file `.env` untuk Laravel (tidak ikut repo):
```bash
cd ~/projects/laravel-test
cp .env.example .env
nano .env
#   APP_ENV=production
#   APP_DEBUG=false
#   APP_URL=http://app.laravel-test.com
#   DB_CONNECTION=pgsql
#   DB_HOST=postgres-db
#   DB_PORT=5432
#   DB_DATABASE=laravel-test
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

Entrypoint container `laravel-app` otomatis menjalankan:
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
cd ~/projects/laravel-test
sudo mkdir -p storage/framework/{cache/data,sessions,views} storage/logs bootstrap/cache
sudo chown -R www-data:www-data storage bootstrap/cache
sudo chmod -R 775 storage bootstrap/cache
```

> Jika container dijalankan dengan `user:` khusus (bukan root), ganti `www-data`
> sesuai user pada `FPM_USER`/`FPM_GROUP`.

### 10) DNS / pengujian domain

- **Produksi:** buat A record domain (`app.laravel-test.com`) → `IP_VPS`.
- **Uji cepat tanpa DNS:** sunting file `hosts` di komputer lokal, tambahkan
  `IP_VPS  app.laravel-test.com`.

Uji dari VPS:
```bash
curl -I http://localhost                                        # 200/302
curl -H "Host: app.laravel-test.com" http://localhost/photos
```

---

## 🔐 Akses Database lewat pgAdmin 4 (tanpa membuka port 5432)

**Cara A — SSH Tunnel dari dalam pgAdmin 4**
1. Klik kanan *Servers* → **Register** → **Server…**
2. Tab **General**: Name = `VPS Laravel`
3. Tab **Connection**: Host = `localhost`, Port = `5432`,
   Maintenance DB = `laravel-test`, Username = `postgres`, Password = password Anda
4. Tab **SSH Tunnel**: centang *Use SSH tunneling* → Tunnel host = `IP_VPS`,
   Port = `22`, Username = user VPS
5. **Save** → pgAdmin membuat tunnel otomatis.

**Cara B — tunnel manual via terminal**
```bash
ssh -L 5432:postgres-db:5432 user@IP_VPS -N
# lalu di pgAdmin connect ke host: localhost, port: 5432
```

---

## ⚙️ GitHub Actions (Auto Deploy)

| Repo | File workflow | Fungsi |
|------|---------------|--------|
| `docker-ecosystem` | `.github/workflows/deploy-infra.yml` | Validasi compose + deploy infra ke VPS |
| `laravel-test` | `.github/workflows/deploy.yml` | Test (PHPUnit) + deploy aplikasi (rebuild, migrate, cache) |

> ⚠️ GitHub **hanya** membaca workflow dari `.github/workflows/` di **root repo**.
> Workflow di subfolder (mis. `app-laravel-docker/.github/...`) tidak akan dijalankan.

### Secrets di GitHub (isi di KEDUA repo)

Repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**:

| Secret | Contoh | Keterangan |
|--------|--------|------------|
| `VPS_HOST` | `203.0.113.10` | IP/hostname VPS |
| `VPS_USER` | `deployer` | user SSH untuk deploy |
| `VPS_SSH_KEY` | `-----BEGIN OPENSSH PRIVATE KEY-----…` | **private key** SSH |
| `VPS_PORT` | `22` | port SSH |
| `VPS_INFRA_PATH` | `/home/deployer/projects/docker-ecosystem` | path repo infra di VPS |
| `VPS_APP_PATH` | `/home/deployer/projects/laravel-test` | path repo app (khusus repo Laravel) |

### Membuat SSH key khusus deploy

```bash
ssh-keygen -t ed25519 -C "github-actions-deploy" -f ~/.ssh/deploy_key -N ""
ssh-copy-id -i ~/.ssh/deploy_key.pub user@IP_VPS
cat ~/.ssh/deploy_key      # salin seluruh isi ini ke secret VPS_SSH_KEY
```

---

## 🧰 Cheatsheet Pemeliharaan

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

## 🩺 Troubleshooting

| Gejala | Sebab | Solusi |
|--------|-------|--------|
| `network shared-network not found` | network belum dibuat | `docker network create shared-network` lalu `docker compose up -d` ulang |
| 502 Bad Gateway | `laravel-nginx` / `app` mati | `docker compose ps` & `docker compose logs laravel-nginx` |
| "Class not found" | `vendor/` belum ada | `docker compose exec app composer install --no-dev -o` |
| **`mkdir ... Permission denied` + container restart terus** | UID container ≠ owner folder di host | perbaiki file compose/entrypoint terbaru (container jalan sebagai root + `chown www-data`), lalu `docker compose up -d --build app`. Sementara: `sudo chown -R www-data:www-data storage bootstrap/cache` |
| **`Composer could not find a composer.json file` / `/var/www/html` kosong** | path volume salah → Docker membuat folder kosong | cek `LARAVEL_APP_PATH`; default harus `../../laravel-test` (sibling repo), bukan `../laravel-test` |
| **`No application encryption key has been specified`** | `APP_KEY` belum di-set | isi `APP_KEY` di `app-laravel-docker/.env.docker`, lalu recreate container |
| Unggah foto gagal (permission) | owner `storage` tidak sesuai | `sudo chown -R www-data:www-data storage bootstrap/cache` |
| `route:cache` gagal | route berbasis Closure | pakai `Route::view('/', 'welcome')` |
| DB connection refused | app & db beda network, DB belum siap | pastikan keduanya di `shared-network`, cek log `postgres-db` |
| Port 80 sudah dipakai | Apache/Nginx di host aktif | `sudo systemctl stop apache2 nginx` |

---

## 📌 Catatan

- **Keamanan:** `.env.docker` ikut ter-commit dan berisi kredensial — **ganti password**
  sebelum online. Jika repo publik, pertimbangkan memakai `.env.docker.example`.
- **Kustomisasi RAM:** nilai di `db-postgres-docker/postgres/conf.d/shared-buffer.sql`
  dioptimalkan untuk VPS ±6 GB. Sesuaikan bila berbeda.
- **HTTPS:** blok SSL di `reverse-proxy-docker/nginx/default.conf` masih dikomentari.
  Aktifkan setelah punya sertifikat (mis. Let's Encrypt/Certbot).


