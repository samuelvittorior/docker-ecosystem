# Redis Bersama (`redis-shared-docker`)

Satu Redis untuk **beberapa aplikasi**, pola sama seperti `db-postgres-docker`.

```
Internet
   │
   ▼
reverse-proxy ──┐
                │ shared-network
postgres-db ────┤
redis-shared ───┤   ← Redis untuk SEMUA aplikasi
                │
   attendapp-app ┘   (REDIS_HOST=redis-shared)
```

---

## ⚠️ Beda penting: Redis ≠ PostgreSQL

| | PostgreSQL | Redis |
|---|---|---|
| Isolasi data | Database/tabel/schema terpisah + `GRANT` per objek | **Tidak ada.** "Database" hanya nomor `0`–`15` dalam satu keyspace, tanpa hak akses per nomor |
| Batas memori | Bisa per role/setting | `maxmemory` **global** untuk seluruh instance |
| Hapus data | `DROP DATABASE` hanya 1 database | `FLUSHALL` = **semua aplikasi hilang** |

Karena itu, satu-satunya cara aman berbagi Redis adalah **disiplin penomoran DB**:

## 📋 Alokasi Nomor DB (WAJIB dipatuhi)

Setiap aplikasi memakai dua nomor DB yang **tidak boleh bertabrakan**:

| Aplikasi | `REDIS_DB` (session/queue/lock) | `REDIS_CACHE_DB` (cache) |
|---|---|---|
| attendapp | `0` | `1` |
| app-kedua | `2` | `3` |
| app-ketiga | `4` | `5` |
| … | `2n` | `2n + 1` |

Tambahkan juga `REDIS_PREFIX` unik per aplikasi (default: dari `APP_NAME`,
mis. `attendapp_database_`). Prefix ini mencegah tabrakan nama key antar aplikasi.

> **Kenapa harus dipisah per nomor DB?** `php artisan cache:clear` melakukan
> `FLUSHDB` pada nomor DB yang dipakai cache. Kalau dua aplikasi memakai nomor
> DB yang sama, cache:clear di aplikasi A akan **menghapus cache aplikasi B**.
> Untuk pengaman, `FLUSHALL`/`FLUSHDB`/`KEYS` sudah dinonaktifkan di `redis.conf`.

---

## 🚀 Menjalankan

```bash
cd ~/projects/docker-ecosystem

# network bersama (sekali saja)
docker network inspect shared-network >/dev/null 2>&1 || docker network create shared-network

cd redis-shared-docker
docker compose up -d
docker compose logs --tail=20 redis
```

Cek koneksi & auth:
```bash
docker exec -it redis-shared sh -c 'redis-cli -a "$REDIS_PASSWORD" ping'
# PONG
```

---

## 🔌 Memakai dari aplikasi

Di `.env`/`.env.docker` aplikasi:

```env
CACHE_DRIVER=redis
SESSION_DRIVER=redis
REDIS_CLIENT=phpredis
REDIS_HOST=redis-shared        # ← alias DNS di shared-network
REDIS_PORT=6379
REDIS_PASSWORD=SI_SECRET_PASSWORD_RDS1   # ← samakan dengan .env.docker di sini
REDIS_DB=0                     # ← nomor unik per aplikasi
REDIS_CACHE_DB=1               # ← nomor unik per aplikasi
REDIS_PREFIX=attendapp_
REDIS_TIMEOUT=2
REDIS_READ_TIMEOUT=5
```

Aplikasi juga harus ikut `shared-network` supaya bisa menjangkau `redis-shared`:

```yaml
services:
  app:
    networks:
      shared-network:
        aliases: [app, attendapp-app]
```

---

## 🔐 Keamanan

- Port **tidak** dipublikasikan ke host → tidak terjangkau dari internet.
- Password wajib (`--requirepass`), dibaca dari `.env.docker`.
- `FLUSHALL`, `FLUSHDB`, `KEYS`, `DEBUG` dinonaktifkan; `CONFIG` di-rename.
- Akses dari luar VPS (mis. RedisInsight) lewat SSH tunnel:
  ```bash
  ssh -N -L 6379:127.0.0.1:6379 user@IP_VPS
  ```
  dan aktifkan dulu `ports: ["127.0.0.1:6379:6379"]` di `docker-compose.yml`.

---

## 💾 Persistensi & Backup

- AOF aktif (`appendonly yes`, `appendfsync everysec`) → session bertahan saat
  container restart.
- Data ada di volume `redis-shared-docker_redis-data`.
- Backup manual:
  ```bash
  docker exec redis-shared sh -c 'redis-cli -a "$REDIS_PASSWORD" BGREWRITEAOF'
  docker cp redis-shared:/data/appendonly.aof ./redis-backup-$(date +%F).aof
  ```

---

## 🧯 Troubleshooting

| Gejala | Sebab | Solusi |
|---|---|---|
| `NOAUTH Authentication required` | `REDIS_PASSWORD` aplikasi kosong/salah | samakan dengan `redis-shared-docker/.env.docker` |
| `Could not connect to Redis at redis-shared:6379` | container tidak di `shared-network`, atau alias belum terdaftar | `docker network inspect shared-network` harus memuat `redis-shared` |
| `OOM command not allowed when used memory > 'maxmemory'` | policy `noeviction` + memori penuh | naikkan `REDIS_MAXMEMORY`, atau pindahkan cache besar keluar dari Redis |
| Cache aplikasi B hilang setelah aplikasi A `cache:clear` | nomor `REDIS_CACHE_DB` bertabrakan | beri nomor DB berbeda per aplikasi (lihat tabel alokasi) |
| `unknown command 'FLUSHALL'` | memang dinonaktifkan | hapus key spesifik via pola, jangan flush seluruh server |
