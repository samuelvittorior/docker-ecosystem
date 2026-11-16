-- =============================================================================
-- Konfigurasi memori PostgreSQL.
--
-- PENTING: nilai default di bawah dioptimalkan untuk VPS dengan RAM ~6 GB.
-- Bila VPS Anda lebih kecil (2/4 GB), WAJIB disesuaikan -- kalau tidak,
-- PostgreSQL + PHP-FPM + Redis bisa berebut memori sampai SWAP dan semuanya
-- jadi lambat (ini justru sering jadi penyebab "servernya kerasa lemot").
--
-- Cek RAM VPS:  free -h
-- Lalu sesuaikan SATU baris di db-postgres-docker/.env.docker:
--   POSTGRES_TUNING=small    # VPS 1-2 GB RAM
--   POSTGRES_TUNING=medium   # VPS 4 GB RAM
--   POSTGRES_TUNING=large    # VPS 6-8 GB RAM  (default di bawah)
--   POSTGRES_TUNING=custom   # pakai nilai POSTGRES_TUNING_* di .env.docker
--
-- Cara ganti:  docker compose down && docker compose up -d   (lihat README)
--
-- Catatan: baris ini dieksekusi hanya pada INISIALISASI volume postgres-data
-- (docker-entrypoint-initdb.d). Untuk mengubah setelahnya, jalankan SQL yang
-- sama lewat: docker exec -it postgres-db psql -U postgres
-- =============================================================================

\set ON_ERROR_STOP on

-- Nilai dari environment container. File di docker-entrypoint-initdb.d
-- dijalankan oleh psql, dan `\getenv` membaca environment variable container
-- (PostgreSQL 15+). Bila variabel belum diisi, nilainya jadi string kosong
-- sehingga blok pemilihan di bawah jatuh ke profil 'large' (default lama).
-- Sintaks `:'nama'` adalah interpolasi variabel psql -- nilainya dikutip
-- otomatis, jadi tidak bisa dipakai untuk SQL injection.
\getenv tuning POSTGRES_TUNING
-- Bila POSTGRES_TUNING tidak diisi di environment, \getenv TIDAK mengubah
-- variabel -> pakai fallback 'large' (perilaku lama, aman untuk VPS 6 GB).
\if :{?tuning}
\else
  \set tuning 'large'
\endif

-- Nilai awal = profil 'large'. Profil lain menimpanya di bawah.
-- Dengan pola "isi default dulu, timpa bila perlu", variabel yang tidak
-- tersedia di environment tidak pernah menghasilkan SQL kosong/invalid.
\set sb  '1536MB'
\set wm  '32MB'
\set mwm '256MB'
\set ecs '4608MB'
\set mc  '100'

-- Pilih profil berdasarkan POSTGRES_TUNING (small|medium|large|custom).
\if :'tuning' = 'small'
  \set sb  '256MB'
  \set wm  '8MB'
  \set mwm '64MB'
  \set ecs '768MB'
  \set mc  '30'
\elif :'tuning' = 'medium'
  \set sb  '1024MB'
  \set wm  '16MB'
  \set mwm '128MB'
  \set ecs '3072MB'
  \set mc  '50'
\elif :'tuning' = 'custom'
  -- Bila salah satu POSTGRES_TUNING_* tidak diisi, nilai default 'large' di
  -- atas tetap dipakai (lihat penjelasan \getenv di atas).
  \getenv sb  POSTGRES_TUNING_SHARED_BUFFERS
  \getenv wm  POSTGRES_TUNING_WORK_MEM
  \getenv mwm POSTGRES_TUNING_MAINTENANCE_WORK_MEM
  \getenv ecs POSTGRES_TUNING_EFFECTIVE_CACHE_SIZE
  \getenv mc  POSTGRES_TUNING_MAX_CONNECTIONS
\endif

ALTER SYSTEM SET shared_buffers = :'sb';
ALTER SYSTEM SET work_mem = :'wm';
ALTER SYSTEM SET maintenance_work_mem = :'mwm';
ALTER SYSTEM SET effective_cache_size = :'ecs';
ALTER SYSTEM SET max_connections = :'mc';

-- Nilai yang tidak bergantung pada besar RAM (aman untuk semua profil).
ALTER SYSTEM SET wal_buffers = '16MB';
ALTER SYSTEM SET random_page_cost = '1.1';
ALTER SYSTEM SET effective_io_concurrency = '200';

\echo '===== Tuning PostgreSQL diterapkan (profil:' :'tuning' ') ====='
\echo 'shared_buffers      =' :'sb'
\echo 'work_mem            =' :'wm'
\echo 'maintenance_work_mem=' :'mwm'
\echo 'effective_cache_size=' :'ecs'
\echo 'max_connections     =' :'mc'

SELECT pg_reload_conf();

-- CATATAN: shared_buffers & max_connections hanya berlaku setelah RESTART
-- server (bukan reload). Pada eksekusi otomatis saat initdb hal ini sudah
-- otomatis terpenuhi karena PostgreSQL dinyalakan ulang setelah init script.
-- Untuk penerapan manual di database yang sudah berjalan:
--   docker restart postgres-db
-- Verifikasi setelah restart:
--   docker exec -it postgres-db psql -U postgres -c 'SHOW shared_buffers'
\echo 'Selesai. Nilai shared_buffers/max_connections berlaku setelah restart.'

