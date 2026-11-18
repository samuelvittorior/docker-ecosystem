-- ===========================================================================
-- Inisialisasi database & role tambahan: ITHelper dan ItemMonitoring
--
-- File ini dijalankan otomatis oleh PostgreSQL HANYA saat volume `postgres-data`
-- masih KOSONG (docker-entrypoint-initdb.d). Kalau volume sudah berisi data
-- (kasus VPS yang sudah menjalankan AttendApp), file ini TIDAK dijalankan --
-- jalankan manual, lihat blok "CARA MENJALANKAN DI VPS YANG SUDAH BERISI DATA"
-- di bagian bawah file ini.
--
-- Urutan file di folder ini (dijalankan alfabetis):
--   10-attendapp-user-db.sql  -> role + db attendapp
--   20-app-databases.sql      -> role + db ithelper, item_monitoring  (FILE INI)
--   shared-buffer.sql         -> tuning memori (harus tetap terakhir)
--
-- Satu container PostgreSQL dipakai BERSAMA semua aplikasi. Yang memisahkan
-- aplikasi adalah DATABASE + ROLE masing-masing, bukan container terpisah.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1) Role/login khusus tiap aplikasi.
--    Aplikasi TIDAK memakai superuser `postgres` supaya:
--      - salah aplikasi tidak bisa merusak database aplikasi lain
--      - password bisa diganti per aplikasi
--    Password di bawah HARUS sama dengan yang ada di:
--      ithelper-docker/.env.docker     -> DB_USERNAME / DB_PASSWORD
--      imon-docker/.env.docker         -> DB_USERNAME / DB_PASSWORD
--    Ganti password = ubah di kedua tempat, lalu:
--      ALTER ROLE ithelper WITH PASSWORD '...';   (di psql)
--      docker compose up -d --force-recreate app  (di folder app-nya)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'ithelper') THEN
      CREATE ROLE ithelper LOGIN PASSWORD 'SI_SECRET_PASSWORD_P5ANHNCX';
   END IF;
   IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'imon') THEN
      CREATE ROLE imon LOGIN PASSWORD 'SI_SECRET_PASSWORD_Q4W7EMRB';
   END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 2) Database aplikasi, dengan role di atas sebagai OWNER.
--
--    Owner penting di PostgreSQL 15: sejak PG15 hak CREATE pada schema `public`
--    dicabut dari PUBLIC, dan schema `public` dimiliki oleh `pg_database_owner`.
--    Jadi kalau role adalah owner database, migrasi Laravel (CREATE TABLE)
--    otomatis diizinkan tanpa GRANT tambahan.
--
--    `\gexec` = jalankan hasil SELECT sebagai perintah SQL. Dipakai karena
--    CREATE DATABASE tidak boleh berada di dalam blok DO/transaksi.
-- ---------------------------------------------------------------------------
SELECT 'CREATE DATABASE ithelper OWNER ithelper'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'ithelper')\gexec

SELECT 'CREATE DATABASE item_monitoring OWNER imon'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'item_monitoring')\gexec

-- ---------------------------------------------------------------------------
-- 3) Hak akses (jaring pengaman).
--    Hak di bawah berlaku pada database yang SEDANG terhubung, sehingga harus
--    `\connect` dulu ke masing-masing database. Berguna bila role-nya bukan
--    owner (mis. database dibuat manual oleh user lain).
-- ---------------------------------------------------------------------------
\connect ithelper
GRANT ALL PRIVILEGES ON DATABASE ithelper TO ithelper;
GRANT ALL PRIVILEGES ON SCHEMA public TO ithelper;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO ithelper;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO ithelper;

\connect item_monitoring
GRANT ALL PRIVILEGES ON DATABASE item_monitoring TO imon;
GRANT ALL PRIVILEGES ON SCHEMA public TO imon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO imon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO imon;

-- ===========================================================================
-- CARA MENJALANKAN DI VPS YANG SUDAH BERISI DATA
--
-- Gejala kalau lupa: aplikasi baru gagal start dengan
--   SQLSTATE[08006] / FATAL: password authentication failed for user "ithelper"
--   atau  FATAL: database "ithelper" does not exist
--
-- Jalankan dari root repo docker-ecosystem di VPS:
--
--   cd ~/projects/docker-ecosystem
--   docker exec -i postgres-db psql -U postgres -v ON_ERROR_STOP=1 \
--     < db-postgres-docker/postgres/conf.d/20-app-databases.sql
--
-- Aman dijalankan berulang: role & database hanya dibuat bila belum ada.
-- Perintah `\connect` dan `\gexec` adalah perintah psql, jadi file ini HARUS
-- dikirim lewat `psql`, bukan lewat aplikasi lain.
--
-- Verifikasi setelahnya:
--   docker exec postgres-db psql -U postgres -c '\l' | grep -E 'ithelper|item_monitoring'
--   docker exec postgres-db psql -U postgres -c '\du' | grep -E 'ithelper|imon'
-- ===========================================================================
