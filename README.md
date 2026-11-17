# 🐳 Docker Ecosystem — Laravel + PostgreSQL + Redis + Nginx Reverse Proxy

Kumpulan **Docker Compose** yang terpisah namun saling terhubung lewat satu network
bersama (`shared-network`), dirancang untuk VPS kecil (RAM Â±6 GB) dan mudah di-scale
ke banyak aplikasi Laravel.

> Kode aplikasi Laravel **tidak** disimpan di repo ini. Repo ini hanya berisi
> konfigurasi infrastruktur. Kode aplikasi ada di repo terpisah (`attendapp`),
> dan di-mount ke container melalui volume `${LARAVEL_APP_PATH:-../../attendapp}`.

---

## 🏗️ Arsitektur

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

## 📁 Struktur Direktori yang Diharapkan di VPS

Kedua repo harus berada pada **folder induk yang sama** karena volume memakai
path relatif `${LARAVEL_APP_PATH:-../../attendapp}` (dihitung dari folder
`app-laravel-docker/`):

```
home/user/projects/
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
> Bila Anda memakai struktur lain (mis. `attendapp/` di **dalam**
> `docker-ecosystem/`), timpa path-nya lewat file `app-laravel-docker/.env`:
>
> ```bash
> cd ~/projects/docker-ecosystem/app-laravel-docker
> echo 'LARAVEL_APP_PATH=../attendapp' > .env
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

> 🔑 **Soal permission:** container `laravel-app` dijalankan sebagai **root**, lalu
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

## 🔐 Akses Database lewat pgAdmin 4 (SSH Tunnel)

Port 5432 **tidak terbuka ke internet**, tetapi di-bind ke `127.0.0.1` di VPS
(lihat `db-postgres-docker/docker-compose.yml`) sehingga bisa dijangkau lewat SSH tunnel.

### ⚠️ Sumber error "server closed the connection unexpectedly"

pgAdmin membuat tunnel seperti ini:

```
pgAdmin  →  sshd (VPS)  →  <Host>:<Port> yang Anda isi di tab Connection
```

Arti kolom di pgAdmin:

| Kolom | Diisi apa | Catatan |
|-------|-----------|---------|
| **SSH Tunnel → Tunnel host** | `IP_VPS` | server SSH-nya |
| **SSH Tunnel → Tunnel port** | `22` | port SSH |
| **Connection → Host** | `127.0.0.1` | **alamat yang dilihat DARI DALAM VPS**, bukan dari laptop |
| **Connection → Port** | `5432` | port PostgreSQL di dalam VPS |

Kesalahan paling umum: mengisi **Connection → Host** dengan `127.0.0.1` **tanpa**
mengaktifkan SSH tunnel. Akibatnya pgAdmin mencoba `127.0.0.1:5432` di **laptop Anda
sendiri** (bukan VPS) → tidak ada PostgreSQL di sana → koneksi ditutup.

Kesalahan kedua: mengisi **Connection → Host** dengan `postgres-db` atau
`IP_VPS`. Nama container tidak bisa di-resolve oleh `sshd` di host, dan port
5432 tidak terbuka ke publik — dua-duanya gagal.

### Cara A — SSH Tunnel dari dalam pgAdmin 4

1. Pastikan port sudah di-bind di VPS (sekali saja):
   ```bash
   cd ~/projects/docker-ecosystem/db-postgres-docker
   docker compose up -d --force-recreate postgres
   sudo ss -tlnp | grep 5432      # harus muncul 127.0.0.1:5432
   ```
2. Di pgAdmin: klik kanan *Servers* → **Register** → **Server…**
3. Tab **General**: Name = `VPS Laravel`
4. Tab **Connection**:
   - Host = `127.0.0.1`
   - Port = `5432`
   - Maintenance database = `laravel-test`
   - Username = `postgres`, Password = password DB Anda
5. Tab **SSH Tunnel**: centang **Use SSH tunneling**
   - Tunnel host = `IP_VPS`
   - Tunnel port = `22`
   - Username = user SSH VPS Anda
   - Authentication = *Password* atau *Identity file* (private key)
6. **Save** → pgAdmin membuat tunnel otomatis.

### Cara B — tunnel manual via terminal (paling mudah didiagnosis)

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
  exec postgres psql -U postgres -d laravel-test -c '\dt'

# 3) cek log container bila koneksi ditolak
docker logs --tail=50 postgres-db
```

> ❗ Jangan pernah memakai `ports: "5432:5432"` (tanpa `127.0.0.1:`). Itu membuka
> database ke seluruh internet. Binding loopback + SSH tunnel sudah cukup aman.


---

## 🚀 Deploy Manual (repo ini TANPA CI/CD)

Repo `docker-ecosystem` **sengaja tidak memakai GitHub Actions**. Perubahan infra
jarang terjadi, dan satu `git pull` + recreate container di VPS jauh lebih mudah
diaudit daripada pipeline yang menyentuh server produksi secara otomatis.

```bash
ssh user@IP_VPS
cd ~/projects/docker-ecosystem
git status --short                 # pastikan bersih: tidak ada edit manual yang akan tertimpa
git pull --ff-only origin main
```

Lalu recreate **hanya** service yang berubah:

| Yang berubah | Perintah |
|---|---|
| `reverse-proxy-docker/**` (termasuk `nginx/default.conf`, `nginx/extra/*.conf`) | `cd reverse-proxy-docker && docker compose up -d --force-recreate` |
| `app-laravel-docker/{Dockerfile,entrypoint.sh,php/**,nginx/**}` | `cd app-laravel-docker && docker compose up -d --build --force-recreate app laravel-nginx` |
| `app-laravel-docker/.env.docker` | `cd app-laravel-docker && docker compose up -d --force-recreate app` |
| `db-postgres-docker/**` | `cd db-postgres-docker && docker compose up -d` |
| `redis-shared-docker/**` | `cd redis-shared-docker && docker compose up -d --force-recreate` |
| `tools/*.sh`, `README.md` | tidak perlu recreate (dijalankan manual) |

Tiga jebakan yang membuat "sudah `git pull` tapi tidak ada perubahan":

1. **nginx** hanya membaca ulang konfigurasi saat reload/recreate. File memang
   bind-mount (isi container langsung ikut berubah), tapi perubahan baru aktif
   setelah `docker exec <container> nginx -s reload`.
2. **PHP OPcache**: `opcache.validate_timestamps=0` (lihat
   `app-laravel-docker/php/opcache.ini`) → file `.php` baru **tidak** dibaca
   sampai container `app` di-recreate.
3. **`.env.docker`** dibaca saat container start → wajib recreate container,
   bukan cukup reload nginx.
4. **`app` perlu waktu menyala.** Entrypoint menunggu PostgreSQL, menunggu Redis,
   `optimize:clear`, `composer install` (bila `vendor/` belum ada), dan `migrate`
   **sebelum** PHP-FPM siap. Selama proses itu nginx menjawab **502** — normal.
   Tunggu sampai: `curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8101/login`
   mengembalikan `200` (biasanya 10–60 detik).

Verifikasi setelah deploy:

```bash
curl -s  https://attd.kovcc.web.id/login | grep -c 'http://attd.kovcc.web.id'   # harus 0
curl -sI http://IP_VPS:8101/login | head -1                                     # HTTP/1.1 200 OK
docker ps --format '{{.Names}}\t{{.Status}}'
```

### CI/CD aplikasi (`attendapp`) — repo terpisah

Yang memakai GitHub Actions hanya **repo aplikasi**; file workflow-nya ada di repo
aplikasi, bukan di repo ini:

| Repo | File workflow | Fungsi |
|------|---------------|--------|
| `attendapp` | `.github/workflows/deploy.yml` | Test (lint + PHPUnit) lalu deploy ke VPS (pull, composer, migrate, cache, recreate `app`) |

> ⚠️ GitHub **hanya** membaca workflow dari `.github/workflows/` di **root repo**.
> Workflow di subfolder (mis. `app-laravel-docker/.github/...`) tidak akan dijalankan.

### Secrets di repo `attendapp`

Repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**:

| Secret | Contoh | Keterangan |
|--------|--------|------------|
| `VPS_HOST` | `203.0.113.10` | IP/hostname VPS |
| `VPS_USER` | `user` | user SSH; harus bisa menjalankan `docker` (root atau anggota grup `docker`) |
| `VPS_SSH_KEY` | `-----BEGIN OPENSSH PRIVATE KEY-----…` | **private key** SSH, salin lengkap termasuk baris `BEGIN`/`END` |
| `VPS_PORT` | `22` | port SSH (opsional; workflow memakai `22` bila secret kosong) |
| `VPS_INFRA_PATH` | `/home/user/projects/docker-ecosystem` | path repo infra di VPS (tempat `docker compose` aplikasi dijalankan) |
| `VPS_APP_PATH` | `/home/user/projects/attendapp` | path checkout repo aplikasi di VPS |

> ⚠️ `VPS_APP_PATH` harus **clone dari repo aplikasi yang sama** dengan yang
> memicu workflow. Kalau di VPS isinya repo/fork lain, `git pull --ff-only` akan
> ditolak (`diverged`) dan deploy gagal — itu memang pengaman, bukan bug.

### Membuat SSH key khusus deploy

```bash
ssh-keygen -t ed25519 -C "github-actions-deploy" -f ~/.ssh/deploy_key -N ""
ssh-copy-id -i ~/.ssh/deploy_key.pub user@IP_VPS
cat ~/.ssh/deploy_key      # salin seluruh isi ini ke secret VPS_SSH_KEY
```

### Akses `git pull` di VPS (deploy key) — wajib untuk repo privat

Deploy dari GitHub Actions menjalankan `git pull` **di dalam VPS**, bukan di runner.
Karena itu VPS sendiri harus punya kredensial ke repo aplikasi. Tanpa ini, deploy
berhenti dengan:

```
fatal: could not read Username for 'https://github.com': No such device or address
```

Gejala itu berarti: remote repo masih **HTTPS**, repo **privat**, dan git butuh
username/password — sedangkan sesi Actions tidak punya terminal untuk menanyakannya.
Catatan: GitHub **sudah tidak menerima password akun**; yang diterima hanya token
(PAT) atau SSH key.

Pilihan kredensial:

| Cara | Aman? | Kapan dipakai |
|------|-------|---------------|
| **Deploy key (SSH, read-only)** | ✅ terbaik | Hanya untuk `git pull` 1 repo. Bisa dicabut kapan saja, tanpa masa berlaku token |
| Fine-grained PAT (Contents: Read) | ⚠️ cukup | Ingin tetap HTTPS. Token harus punya expiry & dirotasi |
| Classic PAT (scope `repo`) | ❌ hindari | Scope terlalu luas (semua repo) |
| Password akun GitHub | ❌ tidak bisa | Sudah dihapus GitHub sejak 2021 |

#### Langkah deploy key (dijalankan **sebagai user deploy**, bukan root)

```bash
ssh user@IP_VPS                     # user yang sama dengan secret VPS_USER
mkdir -p ~/.ssh && chmod 700 ~/.ssh

# 1) Buat key KHUSUS repo ini (tanpa passphrase agar bisa dipakai non-interaktif)
ssh-keygen -t ed25519 -C "vps-attendapp-deploy" -f ~/.ssh/id_attendapp -N ""
cat ~/.ssh/id_attendapp.pub          # salin seluruh baris ini
```

Kunci privat (`~/.ssh/id_attendapp`) **tetap di VPS** dan tidak pernah masuk secret
GitHub — beda dengan `VPS_SSH_KEY` yang dipakai Actions untuk masuk ke VPS.

```text
2) Buka repo aplikasi di GitHub -> Settings -> Deploy keys -> Add deploy key
   Title : vps-attendapp
   Key   : <isi ~/.ssh/id_attendapp.pub>
   [ ] Allow write access   <- BIARKAN KOSONG (deploy hanya membaca)
```

```bash
# 3) Daftarkan key di ~/.ssh/config (agar tidak menimpa key default user ini)
cat >> ~/.ssh/config <<'EOF'

Host github-attendapp
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_attendapp
    IdentitiesOnly yes
EOF
chmod 600 ~/.ssh/config

# 4) Ubah remote dari HTTPS ke SSH memakai alias di atas
cd ~/projects/attendapp
git remote set-url origin git@github-attendapp:OWNER/attendapp.git   # ganti OWNER
git remote -v                                                        # git@github-attendapp:...
```

```bash
# 5) Verifikasi TANPA prompt password
ssh -T git@github-attendapp
#   -> Hi OWNER/attendapp! You've successfully authenticated, but GitHub does
#      not provide shell access.
git fetch --all --prune && git pull --ff-only origin main && echo "PULL OK"
```

`User git` di `~/.ssh/config` memang begitu dari GitHub (bukan akun bernama `git`).

Bila `ssh -T` gagal `Permission denied (publickey)`: pastikan key ditambahkan di
**repo yang benar**, dan file key/config dimiliki user deploy —
`sudo chown user:user ~/.ssh/id_attendapp ~/.ssh/config`.

#### Alternatif: fine-grained PAT (tetap HTTPS)

Jangan menaruh token di URL remote (bisa terbaca lewat `git remote -v`). Pakai
credential store:

```bash
cd ~/projects/attendapp
git remote set-url origin https://github.com/OWNER/attendapp.git   # tanpa token

git config --global credential.helper store
printf 'https://USERNAME:%s@github.com\n' 'PASTE_PAT_DI_SINI' > ~/.git-credentials
chmod 600 ~/.git-credentials

git fetch --all --prune && echo "FETCH OK"
```

PAT fine-grained cukup diberi **Repository access: hanya repo ini** +
**Permissions → Contents: Read-only**.

> ⚠️ Berbeda dengan deploy key: file `~/.git-credentials` menyimpan token **dalam
> bentuk yang bisa dipakai ulang**, untuk **semua** repo yang diizinkan token itu.
> Kalau token bocor, penyerang bisa `git clone` semua repo tersebut. Deploy key
> terbatas pada satu repo dan bisa dicabut tanpa mengubah kredensial lain — itu
> sebabnya deploy key lebih disarankan.

#### Ringkasan: dua key berbeda, dua fungsi berbeda

| Key | Disimpan di | Dipakai oleh | Fungsi |
|-----|-------------|--------------|--------|
| `VPS_SSH_KEY` (secret GitHub) | Secret repo `attendapp` | `appleboy/ssh-action` di runner | Masuk SSH ke VPS untuk menjalankan deploy |
| Deploy key VPS (`~/.ssh/id_attendapp`) | `~/.ssh` di VPS + Deploy keys repo | `git fetch/pull` **di VPS** | Menarik kode repo privat |

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

## 🌐 Domain & HTTPS (Let's Encrypt + auto-perpanjang)

Contoh di bagian ini memakai subdomain **`attd.kovcc.web.id`**. Ganti dengan
domain Anda sendiri; polanya sama.

### 0) Pembagian port & hasil akhir

Satu port hanya bisa melayani **satu protokol**, jadi pembagiannya dibuat eksplisit:

| Port host | Protokol | Fungsi | URL |
|---|---|---|---|
| **80** | HTTP | **Halaman default nginx** + verifikasi Let's Encrypt. **Bukan** aplikasi. | `http://IP_VPS` |
| **8101** | HTTP | Aplikasi AttendApp (jalur lama, tetap dipakai) | `http://IP_VPS:8101`, `http://attd.kovcc.web.id:8101` |
| **443** | HTTPS | Aplikasi AttendApp + HTTP/2 + HSTS | `https://attd.kovcc.web.id` |

Semua bisa dipakai **bersamaan**; tidak perlu memilih.

> **Kenapa port 80 tidak untuk aplikasi?** Sesuai permintaan: port 80 disisakan
> sebagai halaman default nginx. Tapi endpoint verifikasi sertifikat
> (`/.well-known/acme-challenge/`) **wajib** tetap ada di port 80, karena
> Let's Encrypt selalu memverifikasi lewat port 80. Tanpa itu penerbitan dan
> perpanjangan otomatis sertifikat akan gagal.

> **Kenapa HTTPS tidak di 8101?** Karena 8101 sudah dipakai HTTP. Kalau Anda
> lebih suka `https://attd.kovcc.web.id:8101` daripada port 443, lihat catatan
> di `nginx/extra/attendapp-ssl.conf.example` (perlu mengubah mapping compose).

> Satu hal yang **tidak** bisa: login di domain lalu tetap login saat membuka
> IP:8101. Cookie session terikat ke host, jadi keduanya punya session sendiri.
> Ini normal, bukan kerusakan.

### 1) Arahkan subdomain ke IP VPS (di idwebhost)

**1.1 Catat IP publik VPS**

```bash
curl -4 ifconfig.me
```

**1.2 Tambahkan A record di panel idwebhost**

1. Login ke **idwebhost** → **cPanel** (atau *Client Area → Services → Login to cPanel*).
2. Cari menu **DNS Zone Editor** (di cPanel biasanya di bagian *DOMAINS*).
3. Pilih domain **`kovcc.web.id`** dari dropdown, lalu **Manage**.
4. Klik **+ Add Record** dan isi:

   | Kolom | Isi | Catatan |
   |---|---|---|
   | **Type** | `A` | IPv4 |
   | **Name** | `attd` | **cukup label**, lihat catatan di bawah |
   | **Record** / *Address* | `IP_VPS` | hasil langkah 1.1, mis. `203.0.113.10` |
   | **TTL** | `14400` (atau default) | 4 jam; boleh lebih kecil saat uji |

5. **Add Record** / **Save**.
6. (Opsional) ulangi dengan **Name** `www` bila ingin `www.kovcc.web.id` juga.

> ⚠️ **Kesalahan paling sering:** kolom **Name** diisi `attd.kovcc.web.id`.
> Panel akan menambahkan nama domain lagi di belakangnya sehingga terbentuk
> `attd.kovcc.web.id.kovcc.web.id` — domain tidak akan pernah resolve.
> Cukup tulis **`attd`**.

> ℹ️ Bila panel menampilkan record yang sudah ada untuk `kovcc.web.id` (root),
> **jangan diubah**. Yang ditambahkan hanya record baru untuk `attd`.

> ℹ️ Domain baru dari idwebhost biasanya sudah memakai nameserver idwebhost,
> jadi A record langsung berlaku. Bila Anda memakai nameserver lain
> (Cloudflare, Niagahoster, dll.), A record harus ditambahkan **di sana**,
> bukan di cPanel idwebhost.

**1.3 Verifikasi DNS (jangan lewati)**

```bash
# cara cepat
dig +short attd.kovcc.web.id @1.1.1.1
nslookup attd.kovcc.web.id 8.8.8.8

# cara lengkap (menjelaskan SERVFAIL / NXDOMAIN + cek NS authoritative)
bash tools/dns-check.sh attd.kovcc.web.id
```

Harus keluar **IP VPS Anda**. Lalu baca **status jawabannya** — ini yang
membedakan "masih menunggu" dari "salah setting":

| Status dari resolver publik | Artinya | Tindakan |
|---|---|---|
| `NOERROR` + IP VPS | benar | lanjut ke langkah SSL |
| `NOERROR` tanpa A record | zone hidup, record tidak ada | periksa **Name = `attd`** (bukan `attd.kovcc.web.id`) |
| `NXDOMAIN` | zone hidup, nama tidak ada | record belum dibuat / Name salah |
| **`SERVFAIL`** | **nameserver authoritative gagal menjawab** | lihat catatan di bawah |

> ⚠️ **`SERVFAIL` BUKAN propagasi biasa.** Propagasi menghasilkan `NOERROR` atau
> `NXDOMAIN` (data lama atau tidak ada). `SERVFAIL` berarti nameserver domain
> tidak bisa menjawab sama sekali. Penyebab umum:
>
> 1. **Domain masih baru** — zone belum dibuat/diaktifkan di DNS provider (paling
>    sering pada domain `.web.id` yang baru dibeli). Cek lagi beberapa jam
>    kemudian. Bila > 6 jam, hubungi support idwebhost dengan kalimat:
>    *"zone kovcc.web.id mengembalikan SERVFAIL, mohon cek zone/NS-nya"*.
> 2. **Nameserver domain belum mengarah ke idwebhost** — cek menu Domain →
>    Nameserver di Client Area. Bila memakai nameserver lain (Cloudflare dll.),
>    A record harus dibuat di sana, bukan di cPanel idwebhost.
> 3. **Zone file rusak / record bentrok** (mis. CNAME di root bersamaan A record).
>
> Untuk memastikan, tanyakan langsung ke NS authoritative (bukan 8.8.8.8 yang
> punya cache negatif): `bash tools/dns-check.sh attd.kovcc.web.id` (bagian 2–3).

Bila status sudah `NOERROR` tetapi IP belum benar:

- tunggu 1–30 menit (propagasi; TTL besar bisa sampai beberapa jam),
- pastikan **Name** hanya `attd`, coba resolver lain (`@8.8.8.8`, `@1.1.1.1`),
- di Windows: `ipconfig /flushdns`; di Linux: `sudo resolvectl flush-caches`.

**1.4 Uji sebelum HTTPS**

```
http://attd.kovcc.web.id:8101
```

Harus **menampilkan aplikasi**. Perhatikan: **pakai `:8101`**, karena port 80
sengaja hanya melayani halaman default nginx + verifikasi sertifikat.
Kalau di sini sudah gagal, **jangan lanjut** ke langkah SSL: perbaiki DNS dulu.

### 2) Buka port 80 & 443 di firewall VPS

Let's Encrypt memverifikasi domain lewat **port 80**, dan HTTPS butuh **443**.

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw status | grep -E '80|443'
```

Bila VPS memakai Security Group (AWS/GCP/Azure), buka juga di panel cloud-nya.

---


### 3) Aktifkan HTTPS + HTTP/2

```bash
# sekali saja
sudo apt-get update && sudo apt-get install -y certbot

# ambil konfigurasi terbaru (berisi endpoint ACME + template SSL)
cd ~/projects/docker-ecosystem && git pull
cd reverse-proxy-docker && docker compose up -d --force-recreate && cd ..

# minta sertifikat + tulis config + reload proxy
sudo bash tools/enable-https.sh attd.kovcc.web.id email-anda@gmail.com
```

Ganti `email-anda@gmail.com` dengan email Anda (dipakai Let's Encrypt untuk
notifikasi sertifikat hampir kedaluwarsa).

**Yang dilakukan skrip, berurutan:**

1. Cek DNS tiap domain vs IP publik VPS (peringatan bila beda).
2. Pastikan reverse proxy hidup.
3. **Preflight test**: menulis file uji ke `nginx/certbot/.well-known/...` lalu
   mengambilnya lewat `http://attd.kovcc.web.id/...`. Ini membuktikan port 80,
   DNS, dan bind-mount webroot benar **sebelum** memanggil certbot — jadi
   kalau ada masalah, pesannya jelas (bukan error certbot yang membingungkan).
4. `certbot certonly --webroot` → **tanpa mematikan proxy** (nol downtime).
5. Menyalin `fullchain.pem` + `privkey.pem` ke `nginx/certs/`.
6. Menulis `nginx/extra/attd.kovcc.web.id.conf` dari template
   (`server_name` + `http2 on` + redirect http→https + HSTS).
7. **Validasi `nginx -t` di container sekali-pakai**. Bila config salah, file
   SSL dibatalkan dan proxy yang sedang melayani tetap hidup.
8. Recreate proxy, lalu menguji `https://`, redirect 301, dan memastikan
   `http://IP:8101` masih 200.

### 4) Sesuaikan `.env` aplikasi

Di **dua** file: `attendapp/.env` dan `app-laravel-docker/.env.docker`.

```ini
APP_URL=https://attd.kovcc.web.id
APP_FORCE_HTTPS=false     # <-- WAJIB false (lihat penjelasan)
```

```bash
cd ~/projects/docker-ecosystem/app-laravel-docker
docker compose up -d --force-recreate app
```

**Kenapa `APP_FORCE_HTTPS=false`, bukan `true`?**

`AppServiceProvider` memanggil `URL::forceScheme('https')` **tanpa syarat** bila
nilai ini `true`. Artinya *semua* URL — termasuk yang dibuat saat Anda membuka
`http://IP:8101` — akan menjadi `https://IP:8101`, padahal IP tidak punya
sertifikat → halaman gagal/mixed content. Jadi:

| `APP_FORCE_HTTPS` | `https://domain` | `http://IP:8101` |
|---|---|---|
| `false` (disarankan) | benar (https) | benar (http) |
| `true` | benar (https) | **rusak** (aset & redirect ke https://IP) |

Dengan `false`, Laravel mengikuti skema request sebenarnya. Itu hanya bisa
bekerja bila header `X-Forwarded-Proto` dari nginx **dipercaya** — karena itu
`app/Http/Middleware/TrustProxies.php` di repo aplikasi diisi:

```php
protected $proxies = '*';
```

Sebelumnya properti itu kosong, sehingga `X-Forwarded-Proto` diabaikan dan
halaman https tetap menghasilkan URL `http://` (CSS/JS diblokir browser
sebagai mixed content). Bila Anda memakai repo aplikasi versi lama, pastikan
perubahan ini sudah ikut (`git pull`).

**Penting: `TrustProxies` saja tidak cukup.** Header `X-Forwarded-Proto` harus
benar-benar **sampai ke PHP**. Rantai request-nya dua lapis:

```
browser --https--> reverse-proxy --http--> attendapp-nginx --FastCGI--> PHP-FPM
        (X-Forwarded-Proto: https)      ^
                                        batas ini yang sering bocor
```

nginx di container `attendapp-nginx` menerima koneksi **http** dari reverse
proxy, jadi `$https` kosong dan `fastcgi_params` bawaan mengirim
`REQUEST_SCHEME=http` tanpa `HTTPS`. Akibatnya Laravel melihat request sebagai
http dan `asset()`/`url()` menghasilkan `http://...` — persis gejala
*"Mixed Content: ... requested an insecure script"*.

Karena itu `app-laravel-docker/nginx/default.conf` meneruskan skema asli:

```nginx
map $http_x_forwarded_proto $fastcgi_https  { default off;  ~*^https on; }
map $http_x_forwarded_proto $fastcgi_scheme { default http; ~*^https https; }

location ~ \.php$ {
    include fastcgi_params;                      # bawaan (nilainya ditimpa di bawah)
    fastcgi_param HTTPS                  $fastcgi_https;
    fastcgi_param REQUEST_SCHEME         $fastcgi_scheme;
    fastcgi_param HTTP_X_FORWARDED_PROTO $http_x_forwarded_proto if_not_empty;
    fastcgi_param HTTP_X_FORWARDED_HOST  $http_host if_not_empty;
    fastcgi_param HTTP_HOST              $http_host;
}
```

Karena memakai nilai `X-Forwarded-Proto` (bukan `HTTPS on` hardcode), jalur
`http://IP:8101` tetap http — bukan dipaksa https.

Cara cepat memastikan sudah benar:

```bash
curl -s https://attd.kovcc.web.id/login | grep -c 'http://attd.kovcc.web.id'   # harus 0
```

### 5) Verifikasi hasil

```bash
# 1. https melayani aplikasi
curl -sI https://attd.kovcc.web.id | head -3

# 2. port 80 untuk domain ini: HANYA verifikasi sertifikat
curl -sI http://attd.kovcc.web.id | head -2              # 200 + teks pendek (bukan aplikasi)

# 3. HTTP/2 aktif di 443
curl -sI https://attd.kovcc.web.id | head -1        # harus "HTTP/2 200"

# 4. sertifikat benar & berlaku 90 hari
echo | openssl s_client -servername attd.kovcc.web.id -connect attd.kovcc.web.id:443 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates

# 5. jalur lama masih hidup (HTTP)
curl -sI http://IP_VPS:8101/ | head -1                    # 200/302 (BUKAN error)
```

Di browser: buka `https://attd.kovcc.web.id`, cek **gembok**, lalu buka
**DevTools → Console** — harus **tidak ada** peringatan *mixed content*.
DevTools → Network → kolom **Protocol** harus `h2`.


### 6) Perpanjangan otomatis (auto-renew)

Sertifikat Let's Encrypt berlaku **90 hari**. Skrip `tools/renew-https.sh`
memperpanjang lewat **webroot** (proxy tetap hidup, **nol downtime**), lalu
menyalin sertifikat baru ke `nginx/certs/` dan me-reload nginx.

**6.1 Uji dulu tanpa mengubah apa pun**

```bash
cd ~/projects/docker-ecosystem
sudo bash tools/renew-https.sh --dry-run
```

**6.2 Uji sungguhan (aman; hanya memperpanjang bila sisa < 30 hari)**

```bash
sudo bash tools/renew-https.sh
```

**6.3 Pasang cron harian**

```bash
sudo crontab -e
```

Tambahkan satu baris (sesuaikan path repo & user):

```cron
# Perpanjang sertifikat Let's Encrypt tiap hari 03:17, catat log
17 3 * * * cd /home/deployer/projects/docker-ecosystem && /usr/bin/bash tools/renew-https.sh >> /var/log/cert-renew.log 2>&1
```

Cek hasilnya kapan saja:

```bash
sudo tail -30 /var/log/cert-renew.log
```

> **Kenapa tidak cukup `certbot renew` bawaan?**
> Paket `certbot` dari apt sudah memasang timer `certbot.timer`, dan timer itu
> memang memperpanjang sertifikat di `/etc/letsencrypt/`. Tetapi nginx memakai
> **salinan** di `nginx/certs/`, dan salinan itu hanya diperbarui oleh
> `tools/renew-https.sh`. Jadi biarkan timer berjalan (tidak berbahaya —
> `certbot renew` idempoten) **dan** pasang cron di atas. Kalau ingin satu
> sumber saja: `sudo systemctl disable --now certbot.timer`, lalu andalkan cron.

> **Catatan keamanan:** jangan commit isi `nginx/certs/`. Sudah di-`.gitignore`
> (`certs/*` dikecualikan, hanya `.gitkeep` yang ikut). Private key
> (`.key`) diberi permission `640`.

### 7) Menambah subdomain/domain lain nanti

Skrip ini membuat **satu file config per domain**, jadi tidak saling menimpa.

```bash
# subdomain lain untuk aplikasi yang sama (file config terpisah)
sudo bash tools/enable-https.sh absen.kovcc.web.id email-anda@gmail.com

# atau satu sertifikat untuk beberapa nama sekaligus (SAN, lebih hemat)
sudo bash tools/enable-https.sh attd.kovcc.web.id email-anda@gmail.com www.kovcc.web.id
```

Setelah itu tambahkan A record baru di idwebhost (langkah 1) untuk tiap nama.

#### 7a) Aplikasi LAIN (port lain) juga bisa dapat HTTPS di port 443 — bukan cuma satu app

Ini pertanyaan yang sering muncul: *"kalau nanti ada app kedua yang jalan di
port 8102, apakah bisa tampil di `https://app2.domain.com` **tanpa** menulis
port di URL? Bukankah IP publik cuma satu?"*

**Bisa, dan itulah fungsi reverse proxy.** Satu IP publik **tidak** berarti satu
aplikasi. nginx memilih tujuan berdasarkan **nama domain**, bukan port:

| Lapisan | Yang menentukan tujuan |
|---|---|
| HTTP (port 80) | header `Host: app2.domain.com` |
| HTTPS (port 443) | **SNI** saat TLS handshake (`server_name` pada blok `listen 443 ssl`) |

Jadi alurnya:

```
Pengunjung -> https://app2.kovcc.web.id  (port 443, tanpa port aneh)
           -> nginx reverse-proxy (1 IP publik, TLS berakhir di sini)
           -> proxy_pass http://app2-nginx:80   (jaringan Docker internal)
           -> aplikasi kedua
```

Yang penting dipahami:

- Port internal aplikasi (8101, 8102, 8500, …) **tidak ada hubungannya** dengan
  URL publik. Pengunjung selalu melihat 443.
- Port internal itu bahkan **tidak perlu dibuka** di UFW. Kalau hanya diakses
  lewat domain, bind saja ke `127.0.0.1:8102` atau jangan `ports:` sama sekali
  (cukup `expose:`), sehingga tidak ada jalur bypass HTTPS.
- Jumlah subdomain yang bisa dilayani **tidak terbatas** oleh 1 IP publik —
  batasnya RAM/CPU VPS.
- Yang **tidak** bisa: dua aplikasi berbeda berbagi satu port untuk protokol
  **non-HTTP** (mis. SSH, game server, protokol TCP kustom). Untuk protokol
  seperti itu tidak ada `Host`/SNI untuk memilih tujuan, jadi tetap butuh port
  atau IP berbeda.

Caranya di repo ini — cukup satu perintah dengan `--upstream`:

```bash
# 1. A record app2.kovcc.web.id -> IP VPS (idwebhost), tunggu resolve
bash tools/dns-check.sh app2.kovcc.web.id

# 2. Aktifkan HTTPS untuk aplikasi kedua
sudo bash tools/enable-https.sh app2.kovcc.web.id email-anda@gmail.com \
     --upstream app2-nginx:80
```

`--upstream` berisi `host:port` **di dalam jaringan Docker**, bukan di host.
Syaratnya container nginx aplikasi kedua berada di network yang sama dengan
`reverse-proxy` (`shared-network`). Kalau belum:

```bash
docker network connect shared-network <container-nginx-app2>
# atau tambahkan di docker-compose.yml aplikasi:
#   networks: [default, shared-network]
#   networks: { shared-network: { external: true } }
```

Skrip akan memperingatkan dan **berhenti secara default** bila nama upstream
tidak bisa di-resolve dari dalam container `reverse-proxy` — supaya kamu tidak
mendapat 502 yang membingungkan setelah sertifikat terbit.

Hasilnya:

```
nginx/extra/app2.kovcc.web.id.conf   -> listen 443 ssl; server_name app2.kovcc.web.id;
                                        proxy_pass http://app2-nginx:80;
nginx/certs/app2.kovcc.web.id.crt/.key
```

`tools/renew-https.sh` otomatis ikut memperpanjang **semua** sertifikat yang
ada di `nginx/certs/*.crt`, jadi tidak perlu cron tambahan per aplikasi.

Bila satu domain dipakai dua aplikasi (mis. `domain.com` untuk web dan
`api.domain.com` untuk API di container lain), itu tetap dua entri berbeda —
satu `server_name` per file config, upstream masing-masing.

#### 7b) Bandingkan dengan Cloudflare Tunnel

Pola pikirnya **sama** (aplikasi di port internal, publik di 443), bedanya
lokasi reverse proxy-nya:

| | Reverse proxy di VPS (repo ini) | Cloudflare Tunnel |
|---|---|---|
| Butuh IP publik | ya | tidak (koneksi keluar dari origin) |
| Butuh port 80/443 terbuka | ya (80 wajib untuk HTTP-01) | tidak |
| Sertifikat TLS | Let's Encrypt (kamu yang punya) | otomatis di edge Cloudflare |
| Origin IP tersembunyi | tidak | ya |
| Trafik masuk | langsung ke VPS | lewat jaringan Cloudflare |
| Biaya | gratis (+ domain) | gratis, kecuali fitur lanjutan |
| Cocok bila | punya VPS dengan IP publik | ISP blokir 80/443, atau tak mau buka port |

Keduanya **tidak saling meniadakan**: `cloudflared` bisa diarahkan ke
`http://reverse-proxy:80` sehingga aturan routing tetap satu tempat di nginx.
Pilih tunnel bila VPS tidak punya IP publik / port 80 diblokir ISP; kalau IP
publik dan port 80/443 bebas, nginx biasa lebih sederhana (tidak ada
ketergantungan ke pihak ketiga).

### 8) Troubleshooting domain & SSL

| Gejala | Sebab | Solusi |
|---|---|---|
| `nslookup/dig attd.kovcc.web.id` -> **`SERVFAIL`** | nameserver authoritative gagal menjawab - **bukan** propagasi biasa (domain baru belum aktif, NS belum mengarah ke idwebhost, atau zone rusak) | jalankan `bash tools/dns-check.sh attd.kovcc.web.id`; bila >6 jam tetap SERVFAIL, hubungi support idwebhost |
| `dig +short attd.kovcc.web.id` kosong tetapi status `NOERROR`/`NXDOMAIN` | A record belum ada atau **Name** salah | pastikan **Name = `attd`** (bukan `attd.kovcc.web.id`); tunggu 1-30 menit; coba resolver lain |
| `http://IP_VPS:8101` atau `attd.kovcc.web.id:8101` -> **522/523/524** atau timeout | port 8101 tertutup firewall | `sudo ufw allow 8101/tcp`; cek Security Group cloud |
| `http://attd.kovcc.web.id` (tanpa port) menampilkan teks "Port 80 hanya untuk verifikasi" | memang disengaja: port 80 bukan jalur aplikasi | pakai `https://attd.kovcc.web.id` atau `http://attd.kovcc.web.id:8101`. Ini **bukan** error |
| `certbot: Challenge failed ... Invalid response` | port 80 tertutup di tengah jalan, atau ada proxy/CDN di depan | pastikan tidak ada Cloudflare *proxy* (awan oranye) saat penerbitan awal; gunakan DNS-only dulu |
| `nginx: [warn] conflicting server name "attd.kovcc.web.id"` | nama domain didaftarkan juga di `default.conf` | hapus dari `server_name` di `default.conf`; cukup `_` (default_server) |
| `nginx: [emerg] cannot load certificate` | file `.crt`/`.key` tidak ada di `nginx/certs/` | jalankan `sudo bash tools/enable-https.sh ...`; atau hapus `nginx/extra/<domain>.conf` lalu recreate |
| Halaman https tampil **tanpa CSS/JS** (Console: *mixed content*) | `X-Forwarded-Proto` tidak dipercaya **atau** tidak diteruskan ke PHP | 3 hal: (1) `TrustProxies::$proxies = '*'` di repo aplikasi; (2) `fastcgi_param HTTPS`/`HTTP_X_FORWARDED_PROTO` ada di `app-laravel-docker/nginx/default.conf` **dan** `docker exec attendapp-nginx nginx -s reload` (file bind-mount, tapi nginx hanya membaca ulang saat reload); (3) `X-Forwarded-Proto` dikirim reverse-proxy (`grep -c X-Forwarded-Proto nginx/extra/<domain>.conf`). Cek hasil: `curl -s https://<domain>/login \| grep -c http://<domain>` harus **0** |
| Kode app sudah di-`git pull` tetapi perilaku **tidak berubah** (mis. `TrustProxies` masih diabaikan) | `opcache.validate_timestamps=0` + `opcache.enable_file_override=1` di `php/opcache.ini` — PHP-FPM **tidak pernah** membaca ulang file `.php` selama container hidup | `cd app-laravel-docker && docker compose up -d --force-recreate app`. Bukti: `docker inspect -f '{{.State.StartedAt}}' attendapp-app` lebih tua dari `stat -c %y <file.php>`. Bukti tercepat masalah header: `curl -s -H 'X-Forwarded-Proto: https' http://IP_VPS:8101/login \| grep -c 'http://'` — kalau masih > 0, nginx/PHP belum memakai config/kode terbaru |
| `http://IP:8101` error setelah pasang SSL | `APP_FORCE_HTTPS=true` | ubah ke `false`, lalu `docker compose up -d --force-recreate app` |
| Browser menolak http:// setelah pernah https | HSTS (1 tahun) | memang disengaja; gunakan https, atau hapus header HSTS di template lalu tunggu cache browser |
| Renewal gagal tiap hari di log | cron jalan sebelum proxy hidup, atau cert lama masih mode standalone | jalankan `sudo bash tools/renew-https.sh` manual; pastikan proxy `restart: unless-stopped` |

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
sudo bash tools/enable-https.sh attd.kovcc.web.id email-anda@gmail.com
```

Skrip ini memakai mode WEBROOT (proxy TIDAK dimatikan, nol downtime): meminta sertifikat, menyalin ke
`reverse-proxy-docker/nginx/certs/` lalu menulis
`reverse-proxy-docker/nginx/extra/<domain>.conf` (blok 443 ssl + `http2 on`,
sedangkan port 80 hanya untuk verifikasi sertifikat), menjalankan ulang proxy,
dan menguji `https://<domain>`, `http://<domain>:8101`, serta `http://IP:8101`.

Setelah HTTPS berjalan, ubah di **dua** tempat:

```ini
# attendapp/.env  dan  app-laravel-docker/.env.docker
APP_URL=https://attd.kovcc.web.id
APP_FORCE_HTTPS=false   # WAJIB false bila IP:8101 masih dipakai
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

Lima skrip di `tools/` untuk mempermudah operasional di VPS:

| Skrip | Fungsi |
|---|---|
| `tools/diagnose.sh` | **Read-only.** 16 pemeriksaan: status container, port, anggota `shared-network`, config nginx yang benar-benar dimuat (`nginx -T`), tes DNS & HTTP berlapis, cek PHP-FPM, tail log. Jalankan saat ada 502. |
| `tools/reset-stack.sh` | Membersihkan container sisa bernama lama, recreate reverse proxy, build & jalankan stack aplikasi, lalu verifikasi DNS + HTTP. **Tidak** menghapus volume data. |
| `tools/perf-check.sh` | **Read-only.** Cek penyebab lambat dengan angka: RAM/swap, `docker stats`, apakah gzip aktif, **TTFB dari dalam VPS**, cache config/route/view, OPcache, setelan PostgreSQL, memori Redis. |
| `tools/enable-https.sh` | Mengaktifkan **HTTPS + HTTP/2** (Let's Encrypt, mode webroot tanpa downtime): cek DNS + preflight ACME, cek upstream, minta sertifikat, salin ke `nginx/certs/`, tulis `nginx/extra/<nama>.conf`, validasi config di container sekali-pakai, recreate proxy, lalu uji. Idempoten. Opsi `--upstream host:port` untuk **aplikasi lain** (mis. `--upstream app2-nginx:80`) dan `--name` untuk satu domain dengan >1 aplikasi. |
| `tools/renew-https.sh` | **Perpanjangan otomatis** tanpa downtime: `certbot renew` (webroot) -> salin sertifikat yang berubah -> `nginx -s reload`. Jalankan via cron; ada `--dry-run`. |
| `tools/dns-check.sh` | **Read-only.** Diagnosa DNS sebelum pasang SSL: NS domain, SOA dari NS authoritative, A record, terjemahan status `NOERROR`/`NXDOMAIN`/**`SERVFAIL`**, dan jejak delegasi. Jalankan saat domain belum resolve. |

```bash
cd ~/projects/docker-ecosystem
bash tools/diagnose.sh      # kalau ada masalah (502, 404, dll)
bash tools/perf-check.sh    # kalau terasa lambat
bash tools/reset-stack.sh   # kalau perlu bersih-bersih & jalan ulang
sudo bash tools/enable-https.sh attd.kovcc.web.id email@gmail.com   # aktifkan HTTPS
sudo bash tools/renew-https.sh            # perpanjang (cron harian)
bash tools/dns-check.sh attd.kovcc.web.id   # kalau domain belum resolve

> **Penting — nama service ≠ nama DNS.** Nama yang bisa di-resolve antar
> container hanyalah **nama service Compose** atau **`aliases`** pada network,
> **bukan** `container_name`. Itulah sebabnya
> `app-laravel-docker/docker-compose.yml` mendaftarkan
> `aliases: [attendapp-nginx, laravel-nginx]` (untuk nginx) dan
> `aliases: [app, attendapp-app, app-fpm]` (untuk PHP-FPM).

---


## 🩺 Troubleshooting

| Gejala | Sebab | Solusi |
|--------|-------|--------|
| `network shared-network not found` | network belum dibuat | `docker network create shared-network` lalu `docker compose up -d` ulang |
| 502 Bad Gateway | `attendapp-nginx` / `app` mati | `docker compose ps` & `docker compose logs laravel-nginx` |
| **`502` + log `==> vendor/ belum ada, menjalankan composer install...` berulang** | `composer install` gagal → entrypoint `exit 1` → Docker restart-loop → `app` tidak pernah listen di `:9000` → nginx balas 502 | cek pesan Composer di `docker compose logs app`; penyebab tersering `composer.lock` tidak kompatibel dengan PHP container (lihat baris berikut) |
| **`nette/schema v1.2.2 requires php >=7.1 <8.2 -> your php version (8.2.35) does not satisfy that requirement`** | lock lama (dependensi transitif `league/config`) dibatasi PHP < 8.2, sedangkan image memakai PHP 8.2 | sudah diperbaiki: `nette/schema` dinaikkan ke v1.4.0 (`php 8.1 - 8.6`), `nette/utils` v4.0.11, `league/config` v1.2.0. Terapkan dengan `git pull` di repo aplikasi lalu `docker compose up -d --build app`. Bila memakai lock sendiri: `composer update nette/schema league/config --with-dependencies` |
| **`fatal: detected dubious ownership in repository at '/var/www/html'`** | folder aplikasi di-bind-mount dan dimiliki user host, sedangkan proses container berjalan sebagai `root` | sudah diperbaiki: entrypoint menjalankan `git config --global --add safe.directory /var/www/html`. Manual: `docker compose exec app git config --global --add safe.directory /var/www/html` |
| **`!! Redis belum siap setelah 30 detik` padahal Redis hidup** | pengecekan lama memakai `echo > /dev/tcp/...` yang merupakan fitur **bash**, sedangkan `/bin/sh` di Alpine = BusyBox ash | sudah diperbaiki: entrypoint memakai `php -r` + `fsockopen`. Pastikan juga `REDIS_HOST=redis-shared` & `REDIS_PORT=6379` |
| **Deploy berhenti di `http://127.0.0.1:8101/login -> 502`, log app terakhir `==> Menunggu Redis siap...`** | Dua kemungkinan: (a) health check menabrak container yang **belum selesai** menjalankan entrypoint (tunggu PostgreSQL + Redis + composer + migrate butuh puluhan detik) — bukan kerusakan; (b) Redis bersama benar-benar tidak terjangkau, biasanya karena container `redis-shared` yang berjalan **tidak menempel di `shared-network`** (container lama dari compose sebelum alias ditambahkan) | (a) workflow `attendapp` versi terbaru menunggu maks 180 detik (`tunggu_siap`); uji manual: `curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8101/login` (tunggu 30 detik dulu). (b) `docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' redis-shared` → **harus** berisi `shared-network`; kalau tidak: `cd ~/projects/docker-ecosystem/redis-shared-docker && docker compose up -d --force-recreate`. Verifikasi kredensial: `bash tools/why-500.sh` bagian 3 |

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
| **`nginx: [emerg] cannot load certificate`** setelah mengaktifkan HTTPS | file `.crt`/`.key` tidak ada di `reverse-proxy-docker/nginx/certs/` | jalankan `bash tools/enable-https.sh <domain> <email>`; bila sertifikat sudah tidak dipakai, hapus `nginx/extra/<domain>.conf` lalu recreate proxy |
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
- **HTTPS:** blok SSL **dipisah** ke `reverse-proxy-docker/nginx/extra/` (satu file per
  domain, dari template `attendapp-ssl.conf.example`) supaya `default.conf` tetap valid
  sebelum sertifikat ada. Aktifkan dengan `sudo bash tools/enable-https.sh <domain> <email>`,
  perpanjangan otomatis dengan `sudo bash tools/renew-https.sh` + cron. Panduan lengkap:
  bagian **Domain & HTTPS**.
- **Dual access (domain + IP:8101):** biarkan `APP_FORCE_HTTPS=false` dan pastikan
  `TrustProxies::$proxies = '*'` di repo aplikasi. Menyalakan `APP_FORCE_HTTPS=true`
  akan merusak akses lewat `http://IP:8101` (diarahkan ke https yang tidak punya sertifikat).
- **Penting saat update kode aplikasi:** `git pull` di VPS tidak menghapus `vendor/`
  yang isinya tidak lengkap/korup (vendor di-`.gitignore`). Bila `vendor/autoload.php`
  ada padahal paketnya tidak lengkap, entrypoint menganggap instalasi sudah selesai.
  Bersihkan sekali dengan:
  ```bash
  cd ~/projects/attendapp && rm -rf vendor
  cd ~/projects/docker-ecosystem/app-laravel-docker && docker compose up -d --force-recreate app
  ```



