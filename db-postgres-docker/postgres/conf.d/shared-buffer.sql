-- Konfigurasi Shared Buffer & Memory PostgreSQL untuk VPS 6GB RAM
-- File ini dijalankan saat container pertama kali diinisialisasi

ALTER SYSTEM SET shared_buffers = '1536MB';
ALTER SYSTEM SET work_mem = '64MB';
ALTER SYSTEM SET maintenance_work_mem = '256MB';
ALTER SYSTEM SET effective_cache_size = '4608MB';
ALTER SYSTEM SET wal_buffers = '16MB';
ALTER SYSTEM SET max_connections = '100';
ALTER SYSTEM SET random_page_cost = 1.1;
ALTER SYSTEM SET effective_io_concurrency = 200;

SELECT pg_reload_conf();