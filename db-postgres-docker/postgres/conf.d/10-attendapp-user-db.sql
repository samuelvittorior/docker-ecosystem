-- ===========================================================================
# Inisialisasi database dan user untuk aplikasi AttendApp
# File ini dijalankan otomatis PostgreSQL saat volume data masih kosong
# (dari folder ./postgres/conf.d yang di-mount ke /docker-entrypoint-initdb.d/)
# ===========================================================================

-- Buat role/login attendapp bila belum ada (agar aplikasi bisa konek sebagai
-- user sendiri, bukan superuser postgres)
DO $$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'attendapp') THEN
      CREATE ROLE attendapp LOGIN PASSWORD 'attendapp';
   END IF;
END
$$;

-- Buat database attendapp (jika belum ada) dan set owner ke role attendapp
SELECT 'CREATE DATABASE attendapp OWNER attendapp'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'attendapp')\gexec

-- Berikan hak akses penuh kepada role attendapp pada database, schema, tabel
-- dan sequence agar migrasi Laravel dapat membuat tabel, index, dll.
GRANT ALL PRIVILEGES ON DATABASE attendapp TO attendapp;
GRANT ALL PRIVILEGES ON SCHEMA public TO attendapp;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO attendapp;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO attendapp;
