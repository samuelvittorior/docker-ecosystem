#!/usr/bin/env bash
# =============================================================================
# enable-https.sh - Aktifkan HTTPS (Let's Encrypt) + HTTP/2 pada reverse proxy
#
# Jalankan di VPS, dari ROOT repo docker-ecosystem:
#   cd ~/projects/docker-ecosystem
#   sudo bash tools/enable-https.sh attd.kovcc.web.id admin@kovcc.web.id
#
# Bisa sekaligus beberapa nama (satu sertifikat, SAN):
#   sudo bash tools/enable-https.sh attd.kovcc.web.id admin@kovcc.web.id www.kovcc.web.id
#
# Untuk APLIKASI LAIN (bukan AttendApp) di VPS yang sama -- satu IP publik bisa
# melayani banyak subdomain karena nginx memilih tujuan lewat SNI/Host:
#   sudo bash tools/enable-https.sh app2.kovcc.web.id admin@kovcc.web.id \
#        --upstream app2-nginx:80
#   (upstream memakai nama container/port DI DALAM jaringan Docker, dan
#    container tersebut harus ada di network yang sama dengan reverse-proxy)
#
# Prasyarat:
#   1. Domain/subdomain sudah mengarah (A record) ke IP VPS ini.
#      Cek: dig +short attd.kovcc.my.id    -> harus sama dengan IP VPS
#           (IP VPS: curl -4 ifconfig.me)
#   2. Port 80 & 443 terbuka:
#      sudo ufw allow 80/tcp && sudo ufw allow 443/tcp
#   3. certbot terpasang:  sudo apt-get install -y certbot
#   4. Reverse proxy BERJALAN:
#      cd reverse-proxy-docker && docker compose up -d
#
# Cara kerja (mode WEBROOT, tanpa mematikan server):
#   Certbot menaruh file challenge di nginx/certbot/.well-known/acme-challenge/,
#   lalu Let's Encrypt mengambilnya lewat http://<domain>/.well-known/... .
#   nginx menyajikan folder itu lewat location ^~ /.well-known/acme-challenge/
#   (lihat reverse-proxy-docker/nginx/default.conf).
#
#   Keuntungan vs mode --standalone (versi lama skrip ini):
#   - reverse proxy TIDAK perlu di-stop -> tidak ada downtime, termasuk saat
#     perpanjangan otomatis (tools/renew-https.sh).
#
# Idempoten: aman dijalankan ulang. Sertifikat yang masih berlaku tidak
# diminta ulang (--keep-until-expiring).
# =============================================================================
set -eu

# Argumen:
#   posisional : <domain> <email> [domain-tambahan ...]
#   --upstream : host:port tujuan proxy DI DALAM jaringan Docker
#                (default: attendapp-nginx:80). Untuk aplikasi lain:
#                --upstream app2-nginx:80
#   --name     : nama file config di nginx/extra (default: <domain>)
DOMAIN=""
EMAIL=""
UPSTREAM="attendapp-nginx:80"
SITE_NAME=""
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --upstream) UPSTREAM="${2:-}"; shift 2 ;;
        --name)     SITE_NAME="${2:-}"; shift 2 ;;
        -h|--help)  echo "Penggunaan: sudo bash tools/enable-https.sh <domain> <email> [domain-tambahan ...] [--upstream host:port] [--name nama]"; exit 0 ;;
        --*)        echo "Opsi tidak dikenal: $1"; exit 1 ;;
        *)          POSITIONAL+=("$1"); shift ;;
    esac
done
DOMAIN="${POSITIONAL[0]:-}"
EMAIL="${POSITIONAL[1]:-}"
EXTRA_DOMAINS=""
if [ "${#POSITIONAL[@]}" -gt 2 ]; then
    EXTRA_DOMAINS="${POSITIONAL[*]:2}"
fi

if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
    echo "Penggunaan: sudo bash tools/enable-https.sh <domain> <email> [domain-tambahan ...] [--upstream host:port] [--name nama]"
    echo "Contoh    : sudo bash tools/enable-https.sh attd.kovcc.web.id admin@kovcc.web.id"
    echo "Contoh app lain: sudo bash tools/enable-https.sh app2.kovcc.web.id admin@kovcc.web.id --upstream app2-nginx:80"
    exit 1
fi

if [ -z "$UPSTREAM" ]; then
    echo "!! --upstream tidak boleh kosong (contoh: attendapp-nginx:80)"
    exit 1
fi
# Semua path relatif terhadap ROOT repo docker-ecosystem (skrip ini di tools/).
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROXY_DIR="$ROOT_DIR/reverse-proxy-docker"
CERT_DIR="$PROXY_DIR/nginx/certs"
EXTRA_DIR="$PROXY_DIR/nginx/extra"
WEBROOT="$PROXY_DIR/nginx/certbot"
TEMPLATE="$EXTRA_DIR/ssl-site.conf.example"
# Nama lama (sebelum template digeneralisasi) tetap didukung bila masih ada
# di checkout VPS yang belum `git pull`.
if [ ! -f "$TEMPLATE" ] && [ -f "$EXTRA_DIR/attendapp-ssl.conf.example" ]; then
    TEMPLATE="$EXTRA_DIR/attendapp-ssl.conf.example"
fi

# Nama file & nama sertifikat mengikuti domain -> menambah subdomain/domain
# (atau aplikasi) lain tidak saling menimpa: tiap domain punya file sendiri.
# `--name` mengubah nama file (berguna bila satu domain dipakai >1 aplikasi
# dengan sertifikat terpisah). nama_sertifikat = SITE_NAME.

# Nama sertifikat/folder letsencrypt. Berbeda dari DOMAIN bila --name diisi.
CERT_NAME="${SITE_NAME:-$DOMAIN}"
LIVE_DIR="/etc/letsencrypt/live/$CERT_NAME"
TARGET_CONF="$EXTRA_DIR/${CERT_NAME}.conf"

# Semua nama yang masuk ke satu sertifikat (domain utama + domain tambahan/SAN).
ALL_DOMAINS="$DOMAIN"
if [ -n "${EXTRA_DOMAINS:-}" ]; then
    ALL_DOMAINS="$DOMAIN $EXTRA_DOMAINS"
fi

hr() { printf '\n=============== %s ===============\n' "$1"; }

hr "0. Pemeriksaan awal"
echo "Nama      : $ALL_DOMAINS"
echo "Upstream  : $UPSTREAM  (tujuan proxy https://$DOMAIN -> port 443)"
echo "Sertifikat: $CERT_NAME"
echo "Config    : $TARGET_CONF"
echo "Email     : $EMAIL"
echo "Root repo : $ROOT_DIR"
echo "Webroot   : $WEBROOT"
if ! command -v certbot >/dev/null 2>&1; then
    echo "!! certbot belum ada. Jalankan: sudo apt-get install -y certbot"
    exit 1
fi
if [ ! -d "$PROXY_DIR" ]; then
    echo "!! $PROXY_DIR tidak ditemukan. Jalankan skrip dari repo docker-ecosystem."
    exit 1
fi
if [ ! -f "$TEMPLATE" ]; then
    echo "!! Template tidak ada: $TEMPLATE (jalankan 'git pull' dulu)."
    exit 1
fi
mkdir -p "$CERT_DIR" "$EXTRA_DIR" "$WEBROOT/.well-known/acme-challenge"

hr "1. Cek DNS: apakah domain sudah mengarah ke VPS ini?"
IP_PUBLIC="$(curl -4 -s --max-time 10 ifconfig.me || echo '?')"
echo "IP publik VPS : $IP_PUBLIC"
DNS_MISMATCH=0
for d in $ALL_DOMAINS; do
    IP_DNS="$(getent hosts "$d" 2>/dev/null | awk '{print $1}' | head -1 || true)"
    echo "  $d -> ${IP_DNS:-<tidak ter-resolve>}"
    if [ -n "$IP_DNS" ] && [ -n "$IP_PUBLIC" ] && [ "$IP_DNS" != "$IP_PUBLIC" ]; then
        DNS_MISMATCH=1
    fi
done
if [ "$DNS_MISMATCH" = "1" ]; then
    echo
    echo "!! PERINGATAN: ada domain yang TIDAK menunjuk ke VPS ini."
    echo "   Let's Encrypt akan menolak (challenge diambil dari IP yang salah)."
    echo "   Perbaiki A record dulu, tunggu propagasi (1-30 menit), lalu ulangi."
    echo "   Langkah DNS lengkap ada di README bagian 'Domain & HTTPS'."
    jawab=n
    read -r -p "   Lanjut saja (kemungkinan besar gagal)? [y/N] " jawab || true
    case "$jawab" in [Yy]*) ;; *) echo "Dibatalkan."; exit 1 ;; esac
fi

hr "2. Pastikan reverse proxy berjalan & webroot dapat diakses dari internet"
if ! docker ps --format '{{.Names}}' | grep -qx 'reverse-proxy'; then
    echo "  reverse-proxy belum berjalan -> menyalakan dulu..."
    (cd "$PROXY_DIR" && docker compose up -d) || {
        echo "!! Gagal menyalakan reverse-proxy."; exit 1; }
    sleep 3
fi

# Uji end-to-end SEBELUM meminta sertifikat: tulis file ke webroot, lalu ambil
# lewat HTTP publik. Ini menangkap penyebab yang tidak terlihat sampai certbot
# gagal: port 80 tertutup firewall, DNS salah, atau volume belum ter-mount.
PROBE_NAME="preflight-$$.txt"
PROBE_VALUE="ok-$$"
echo "$PROBE_VALUE" > "$WEBROOT/.well-known/acme-challenge/$PROBE_NAME"
PROBE_URL="http://$DOMAIN/.well-known/acme-challenge/$PROBE_NAME"
PROBE_GOT="$(curl -s --max-time 15 "$PROBE_URL" || true)"
rm -f "$WEBROOT/.well-known/acme-challenge/$PROBE_NAME"

if [ "$PROBE_GOT" = "$PROBE_VALUE" ]; then
    echo "  OK: $PROBE_URL dapat diakses dari internet (port 80 + webroot benar)."
else
    echo "  !! GAGAL mengambil $PROBE_URL"
    echo "     Isi respons: '${PROBE_GOT:0:120}'"
    echo
    echo "     Periksa satu per satu:"
    echo "     1. DNS mengarah ke IP VPS?      dig +short $DOMAIN"
    echo "     2. Port 80 terbuka?             sudo ufw status | grep 80"
    echo "     3. Proxy memuat config baru?    cd $PROXY_DIR && docker compose up -d --force-recreate"
    echo "        (location /.well-known/acme-challenge/ wajib ada di nginx/default.conf)"
    echo "     4. Webroot ter-mount?           docker exec reverse-proxy ls /var/www/certbot/.well-known"
    echo
    echo "     Catatan: bila http://$DOMAIN menampilkan APLIKASI (bukan teks biasa),"
    echo "     itu NORMAL pada pemasangan PERTAMA (blok redirect https belum ada)."
    echo "     Yang membuat uji ini gagal biasanya DNS atau firewall, bukan nginx."
    exit 1
fi

hr "2b. Cek upstream yang akan menerima trafik HTTPS"
UPSTREAM_HOST="${UPSTREAM%%:*}"
UPSTREAM_PORT="${UPSTREAM##*:}"
if [ "$UPSTREAM_PORT" = "$UPSTREAM" ]; then
    UPSTREAM_PORT=80
fi
echo "  upstream : $UPSTREAM   (host=$UPSTREAM_HOST port=$UPSTREAM_PORT)"
echo "  Catatan  : port $UPSTREAM_PORT TIDAK perlu dibuka di firewall. Trafik masuk"
echo "             lewat 443 (nginx reverse-proxy), lalu diteruskan ke upstream di"
echo "             dalam jaringan Docker. Satu IP publik bisa melayani banyak app."
if docker exec reverse-proxy sh -c "getent hosts '$UPSTREAM_HOST' >/dev/null 2>&1"; then
    echo "  OK: $UPSTREAM_HOST ter-resolve dari dalam container reverse-proxy."
else
    echo "  !! $UPSTREAM_HOST TIDAK ter-resolve dari container reverse-proxy."
    echo "     Kemungkinan: container aplikasi berada di network Docker yang berbeda."
    echo "     Perbaiki salah satu:"
    echo "       - daftarkan nginx aplikasi ke network yang sama:"
    echo "         docker network connect shared-network <container-nginx-aplikasi>"
    echo "       - atau tambahkan network 'shared-network' (external) di"
    echo "         docker-compose.yml aplikasi, lalu recreate container-nya."
    echo "     Tanpa ini, https://$DOMAIN akan menghasilkan 502 Bad Gateway."
    jawab=n
    read -r -p "     Lanjut saja (sertifikat tetap dibuat, tapi halaman 502)? [y/N] " jawab || true
    case "$jawab" in [Yy]*) ;; *) echo "Dibatalkan."; exit 1 ;; esac
fi

hr "3. Minta sertifikat Let's Encrypt (webroot, tanpa downtime)"
CERTBOT_ARGS="--webroot -w $WEBROOT --non-interactive --agree-tos -m $EMAIL --cert-name $CERT_NAME"
for d in $ALL_DOMAINS; do
    CERTBOT_ARGS="$CERTBOT_ARGS -d $d"
done
echo "  certbot certonly $CERTBOT_ARGS"
# shellcheck disable=SC2086
sudo certbot certonly $CERTBOT_ARGS --keep-until-expiring

if [ ! -f "$LIVE_DIR/fullchain.pem" ]; then
    echo "!! Gagal: $LIVE_DIR/fullchain.pem tidak ada. Baca output certbot di atas."
    exit 1
fi
echo "  Sertifikat tersedia di $LIVE_DIR"

hr "4. Salin sertifikat ke $CERT_DIR"
sudo cp "$LIVE_DIR/fullchain.pem" "$CERT_DIR/$CERT_NAME.crt"
sudo cp "$LIVE_DIR/privkey.pem"   "$CERT_DIR/$CERT_NAME.key"
# nginx hanya butuh baca; private key tidak perlu world-readable.
sudo chmod 644 "$CERT_DIR/$CERT_NAME.crt"
sudo chmod 640 "$CERT_DIR/$CERT_NAME.key"

hr "5. Tulis konfigurasi nginx untuk HTTPS: $TARGET_CONF"
# Template berisi placeholder __CERT_NAME__, __SERVER_NAMES__, __UPSTREAM__.
sed "s|__CERT_NAME__|$CERT_NAME|g; s|__SERVER_NAMES__|$ALL_DOMAINS|g; s|__UPSTREAM__|$UPSTREAM|g" \
    "$TEMPLATE" > "$TARGET_CONF"
echo "  dibuat: $TARGET_CONF"
grep -nE 'server_name|ssl_certificate' "$TARGET_CONF" | sed 's/^/    /' || true

hr "6. Validasi config SEBELUM menyentuh container yang berjalan"
# Diuji di container sekali-pakai. Bila config SSL salah, reverse-proxy yang
# sedang melayani domain lain TIDAK ikut mati.
if docker run --rm \
        --add-host "$UPSTREAM_HOST:127.0.0.1" \
        -v "$PROXY_DIR/nginx/default.conf:/etc/nginx/conf.d/default.conf:ro" \
        -v "$EXTRA_DIR:/etc/nginx/extra:ro" \
        -v "$CERT_DIR:/etc/nginx/certs:ro" \
        nginx:alpine nginx -t; then
    echo "  OK: config valid."
else
    echo "!! Config nginx TIDAK valid -> file SSL dibatalkan agar proxy tetap hidup."
    rm -f "$TARGET_CONF"
    echo "   Sertifikat tetap tersimpan di $CERT_DIR (aman, belum dipakai)."
    echo "   Perbaiki penyebab di atas lalu jalankan ulang skrip ini."
    (cd "$PROXY_DIR" && docker compose up -d) || true
    exit 1
fi

hr "7. Jalankan ulang reverse proxy"
(cd "$PROXY_DIR" && docker compose up -d --force-recreate) || exit 1
sleep 3
docker exec reverse-proxy nginx -t 2>&1 || true

hr "8. Uji hasil"
echo "  -- https (443):"
curl -s -o /dev/null -w "     status=%{http_code}  http_version=%{http_version}  ttfb=%{time_starttransfer}s\n" \
    "https://$DOMAIN/" || true
echo "  -- http port 80 untuk domain ini (hanya verifikasi, TIDAK ke aplikasi):"
curl -s -o /dev/null -w "     status=%{http_code}\n" "http://$DOMAIN/" || true
# Uji jalur HTTP langsung hanya relevan untuk aplikasi yang memang masih
# mempublikasikan portnya ke host (AttendApp: 8101). Aplikasi lain biasanya
# hanya diakses lewat 443, jadi tidak diuji di sini.
if [ "$UPSTREAM" = "attendapp-nginx:80" ]; then
    echo "  -- http://<domain>:8101 tetap melayani aplikasi:"
    curl -s -o /dev/null -w "     status=%{http_code}\n" "http://$DOMAIN:${APP_HTTP_PORT:-8101}/" || true
    echo "  -- akses lewat IP:8101 harus TETAP jalan:"
    curl -s -o /dev/null -w "     status=%{http_code}\n" "http://127.0.0.1:${APP_HTTP_PORT:-8101}/" || true
else
    echo "  -- upstream $UPSTREAM dari dalam container reverse-proxy:"
    docker exec reverse-proxy sh -c "wget -q -T 5 -O /dev/null 'http://$UPSTREAM/' && echo '     OK: upstream menjawab'" \
        || echo "     !! upstream tidak menjawab (https://$DOMAIN akan 502)"
fi
echo "  -- sertifikat yang dipakai:"
echo | openssl s_client -servername "$DOMAIN" -connect "$DOMAIN:443" 2>/dev/null \
    | openssl x509 -noout -subject -issuer -dates 2>/dev/null || true

cat <<EOF

Selesai. Ringkasan:
  Nama      : $ALL_DOMAINS
  Upstream  : $UPSTREAM   (https://$DOMAIN -> port 443 -> $UPSTREAM)
  Cert      : $CERT_DIR/$CERT_NAME.crt
  Config    : $TARGET_CONF

Jalur akses:
  https://$DOMAIN   -> aplikasi (HTTP/2 + HSTS), lewat port 443
  http://$DOMAIN    -> hanya verifikasi sertifikat (port 80 = halaman default nginx)
  port internal ($UPSTREAM_PORT) TIDAK perlu dibuka di firewall; trafik masuk
  lewat 443 lalu diteruskan nginx ke upstream di jaringan Docker.

Bila ini aplikasi Laravel, sesuaikan juga APP_URL di:
  <aplikasi>/.env  dan  <folder-app-docker>/.env.docker
    APP_URL=https://$DOMAIN
  lalu: cd <folder-app-docker> && docker compose up -d --force-recreate <service-app>

Contoh per aplikasi di ekosistem ini:
  AttendApp       : app-laravel-docker/,  port 8101, APP_URL=https://attd.kovcc.web.id
  ITHelper        : ithelper-docker/,     port 8102, APP_URL=https://desk.kovcc.web.id
  ItemMonitoring  : imon-docker/,         port 8103, APP_URL=https://imon.kovcc.web.id

JANGAN memaksa skema https di kode aplikasi (URL::forceScheme). Jalur
http://IP_VPS:<port> akan ikut rusak. Skema dideteksi dari header
X-Forwarded-Proto; lihat App\Http\Middleware\TrustProxies ($proxies = '*').

Perpanjangan otomatis (sertifikat berlaku 90 hari):
  sudo bash tools/renew-https.sh      # uji manual dulu
  lalu pasang cron -> README bagian 'Perpanjangan otomatis'
EOF
