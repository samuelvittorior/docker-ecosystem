#!/usr/bin/env bash
# =============================================================================
# app-health.sh - Cek kesehatan SEMUA aplikasi di ekosistem (HANYA BACA)
#
# Jalankan di VPS dari root repo docker-ecosystem:
#   cd ~/projects/docker-ecosystem
#   bash tools/app-health.sh
#
# Yang diperiksa (per aplikasi):
#   1. Container app & nginx: status + restart terakhir
#   2. HTTP lewat port host (8101/8102/8103): harus 200
#   3. HTTP lewat domain publik (bila sudah ada): kode + sertifikat
#   4. Alias DNS di shared-network (deteksi nama yang bertabrakan)
#   5. Koneksi database dari dalam container app
#
# Tidak mengubah apa pun. Aman dijalankan kapan saja.
# =============================================================================
set -u

# Format: "label|container_app|container_nginx|port_host|url_path|domain|db"
APPS="
AttendApp|attendapp-app|attendapp-nginx|8101|/login|attd.kovcc.web.id|attendapp
ITHelper|ithelper-app|ithelper-nginx|8102|/login|desk.kovcc.web.id|ithelper
ItemMonitoring|imon-app|imon-nginx|8103|/login|imon.kovcc.web.id|item_monitoring
"

hr() { printf '\n=============== %s ===============\n' "$1"; }
kode_http() { curl -s -o /dev/null -w '%{http_code}' -m 8 "$1" 2>/dev/null || echo "000"; }

hr "0. Container yang berjalan"
docker ps --format '{{.Names}}\t{{.Status}}' | sort || echo "(docker tidak bisa diakses)"

hr "1. Alias DNS di shared-network (tidak boleh ada nama dobel)"
docker network inspect shared-network \
    -f '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null | tr ' ' '\n' | sort | sed '/^$/d' \
    | sed 's/^/  /' || echo "  (network shared-network tidak ada)"

hr "2. Status per aplikasi"
printf '%-16s %-10s %-14s %-10s %s\n' "APLIKASI" "PORT" "KODE(HTTP)" "PANJANG" "CATATAN"
echo "$APPS" | while IFS='|' read -r label app nginx port path domain db; do
    [ -z "${label:-}" ] && continue
    kode="$(kode_http "http://127.0.0.1:$port$path")"
    status_app="$(docker inspect -f '{{.State.Status}}' "$app" 2>/dev/null || echo "-")"
    status_nginx="$(docker inspect -f '{{.State.Status}}' "$nginx" 2>/dev/null || echo "-")"
    catatan="app=$status_app nginx=$status_nginx"
    [ "$kode" != "200" ] && catatan="$catatan  <-- PERIKSA (docker compose logs $app)"
    printf '%-16s %-10s %-14s %-10s %s\n' "$label" "$port" "$kode" "-" "$catatan"
done

hr "3. Akses domain publik (HTTPS)"
echo "$APPS" | while IFS='|' read -r label app nginx port path domain db; do
    [ -z "${label:-}" ] && continue
    kode="$(kode_http "https://$domain$path")"
    if [ "$kode" = "000" ]; then
        echo "  $label ($domain): belum bisa diakses (DNS/SSL belum siap?)"
        continue
    fi
    exp="$(echo | openssl s_client -servername "$domain" -connect "$domain:443" 2>/dev/null \
           | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || echo '?')"
    echo "  $label ($domain): HTTP $kode | sertifikat berlaku s/d ${exp:-?}"
done

hr "4. Koneksi database dari container app"
echo "$APPS" | while IFS='|' read -r label app nginx port path domain db; do
    [ -z "${label:-}" ] && continue
    hasil="$(docker exec "$app" php -r '
        $host = getenv("DB_HOST") ?: "?";
        $name = getenv("DB_DATABASE") ?: "?";
        $user = getenv("DB_USERNAME") ?: "?";
        echo "host=$host db=$name user=$user -> ";
        try {
            $pdo = new PDO("pgsql:host=" . $host . ";port=" . (getenv("DB_PORT") ?: 5432) . ";dbname=" . $name,
                $user, (string) getenv("DB_PASSWORD"), [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
            echo "OK";
        } catch (Throwable $e) {
            echo "GAGAL: " . $e->getMessage();
        }
    ' 2>&1 | tail -1)"
    echo "  $label: ${hasil:-(tidak bisa dijalankan: container $app mati?)}"
done

cat <<'EOF'

Cara membaca hasil:
  - KODE(HTTP) != 200  -> container app belum siap ATAU error. Container baru
    butuh 10-60 detik (entrypoint: tunggu PostgreSQL, migrate, cache).
    Lihat: cd <folder-app-docker> && docker compose logs --tail 60 <container-app>
  - "database ... does not exist" / "password authentication failed"
    -> role & database belum dibuat di PostgreSQL:
       docker exec -i postgres-db psql -U postgres -v ON_ERROR_STOP=1 \
         < db-postgres-docker/postgres/conf.d/20-app-databases.sql
  - Domain 000 -> A record belum ada atau SSL belum diaktifkan
       bash tools/dns-check.sh <domain>
EOF
