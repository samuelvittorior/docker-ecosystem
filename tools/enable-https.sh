#!/usr/bin/env bash
# =============================================================================
# enable-https.sh - Aktifkan HTTPS (Let's Encrypt) + HTTP/2 pada reverse proxy
#
# Jalankan di VPS, dari ROOT repo docker-ecosystem:
#   cd ~/projects/docker-ecosystem
#   bash tools/enable-https.sh app.attendapp.com admin@attendapp.com
#
# Prasyarat:
#   1. Domain sudah mengarah (A record) ke IP VPS ini.
#      Cek dulu: dig +short app.attendapp.com   -> harus sama dengan IP VPS
#      (curl -4 ifconfig.me)
#   2. Port 80 & 443 terbuka:  sudo ufw allow 80/tcp && sudo ufw allow 443/tcp
#   3. certbot terpasang:      sudo apt-get install -y certbot
#   4. Reverse proxy berjalan: cd reverse-proxy-docker && docker compose up -d
#
# Yang dilakukan skrip:
#   1. Menghentikan sementara container reverse-proxy supaya port 80 bebas
#      (certbot --standalone butuh port 80).
#   2. Meminta sertifikat ke Let's Encrypt.
#   3. Menyalin fullchain.pem & privkey.pem ke reverse-proxy-docker/nginx/certs/
#   4. Menulis reverse-proxy-docker/nginx/extra/attendapp-ssl.conf (blok 443 +
#      redirect http->https + HTTP/2).
#   5. Menjalankan ulang reverse proxy & memverifikasi.
#
# Renewal: sertifikat Let's Encrypt berlaku 90 hari, jalankan ulang skrip ini
# (idempoten) atau pasang cron:
#   0 3 1 * * cd /home/USER/projects/docker-ecosystem && bash tools/enable-https.sh DOMAIN EMAIL >/dev/null 2>&1
# =============================================================================
set -eu

DOMAIN="${1:-}"
EMAIL="${2:-}"

if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
    echo "Penggunaan: bash tools/enable-https.sh <domain> <email>"
    echo "Contoh    : bash tools/enable-https.sh app.attendapp.com admin@attendapp.com"
    exit 1
fi

# Semua path relatif terhadap ROOT repo docker-ecosystem (folder skrip ini ada di tools/).
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROXY_DIR="$ROOT_DIR/reverse-proxy-docker"
CERT_DIR="$PROXY_DIR/nginx/certs"
EXTRA_DIR="$PROXY_DIR/nginx/extra"
LIVE_DIR="/etc/letsencrypt/live/$DOMAIN"

hr() { printf '\n=============== %s ===============\n' "$1"; }

hr "0. Pemeriksaan awal"
command -v certbot >/dev/null 2>&1 || { echo "!! certbot belum ada. Jalankan: sudo apt-get install -y certbot"; exit 1; }
[ -d "$PROXY_DIR" ] || { echo "!! $PROXY_DIR tidak ditemukan. Jalankan skrip dari repo docker-ecosystem."; exit 1; }
mkdir -p "$CERT_DIR" "$EXTRA_DIR"
echo "Domain : $DOMAIN"
echo "Email  : $EMAIL"
echo "Root   : $ROOT_DIR"

hr "1. Cek DNS domain mengarah ke VPS ini"
IP_PUBLIC="$(curl -4 -s ifconfig.me || echo '?')"
IP_DNS="$(getent hosts "$DOMAIN" | awk '{print $1}' | head -1 || echo '')"
echo "IP publik VPS : $IP_PUBLIC"
echo "IP domain DNS : ${IP_DNS:-<tidak ter-resolve>}"
if [ -n "$IP_DNS" ] && [ "$IP_DNS" != "$IP_PUBLIC" ]; then
    echo "!! PERINGATAN: DNS tidak menunjuk ke VPS ini."
    echo "   Certbot akan GAGAL bila domain tidak mengarah ke sini."
    # `read` bisa gagal saat skrip dijalankan dari cron (tanpa stdin) -> default 'n'.
    jawab=n
    read -r -p "   Lanjut saja? [y/N] " jawab || true
    case "$jawab" in [Yy]*) ;; *) echo "Dibatalkan."; exit 1 ;; esac
fi

hr "2. Hentikan sementara reverse-proxy (port 80 harus bebas untuk certbot)"
(cd "$PROXY_DIR" && docker compose stop) || echo "  (container mungkin belum jalan, lanjut)"

hr "3. Minta sertifikat (certbot --standalone)"
if [ -d "$LIVE_DIR" ]; then
    echo "  Sertifikat sudah ada -> perpanjang (renew)."
    sudo certbot certonly --standalone --non-interactive --agree-tos -m "$EMAIL" \
        --cert-name "$DOMAIN" --keep-until-expiring -d "$DOMAIN"
else
    sudo certbot certonly --standalone --non-interactive --agree-tos -m "$EMAIL" \
        --cert-name "$DOMAIN" -d "$DOMAIN"
fi

if [ ! -f "$LIVE_DIR/fullchain.pem" ]; then
    echo "!! Gagal: $LIVE_DIR/fullchain.pem tidak ada. Cek output certbot di atas,"
    echo "   lalu jalankan ulang 'cd $PROXY_DIR && docker compose up -d'."
    exit 1
fi

hr "4. Salin sertifikat ke $CERT_DIR"
sudo cp "$LIVE_DIR/fullchain.pem" "$CERT_DIR/$DOMAIN.crt"
sudo cp "$LIVE_DIR/privkey.pem"   "$CERT_DIR/$DOMAIN.key"
# nginx hanya butuh baca.
sudo chmod 644 "$CERT_DIR/$DOMAIN.crt"
sudo chmod 640 "$CERT_DIR/$DOMAIN.key"
ls -l "$CERT_DIR"

hr "5. Tulis konfigurasi nginx untuk HTTPS ($EXTRA_DIR/attendapp-ssl.conf)"
# Template diambil dari file .example di folder yang sama; __DOMAIN__ diganti.
TEMPLATE="$EXTRA_DIR/attendapp-ssl.conf.example"
[ -f "$TEMPLATE" ] || { echo "!! Template $TEMPLATE tidak ada (git pull dulu)."; exit 1; }
sed "s/__DOMAIN__/$DOMAIN/g" "$TEMPLATE" > "$EXTRA_DIR/attendapp-ssl.conf"
echo "  dibuat: $EXTRA_DIR/attendapp-ssl.conf"

hr "6. Validasi config SEBELUM menyentuh container yang berjalan"
# Uji di container sekali-pakai. Kalau config SSL salah, reverse-proxy yang
# sedang melayani domain lain TIDAK ikut mati.
VALIDATE_OK=1
docker run --rm \
    --add-host attendapp-nginx:127.0.0.1 \
    -v "$PROXY_DIR/nginx/default.conf:/etc/nginx/conf.d/default.conf:ro" \
    -v "$PROXY_DIR/nginx/extra:/etc/nginx/extra:ro" \
    -v "$PROXY_DIR/nginx/certs:/etc/nginx/certs:ro" \
    nginx:alpine nginx -t || VALIDATE_OK=0

if [ "$VALIDATE_OK" != "1" ]; then
    echo "!! Config nginx TIDAK valid -> file SSL dibatalkan agar proxy tetap hidup."
    rm -f "$EXTRA_DIR/attendapp-ssl.conf"
    echo "   Sertifikat sudah tersalin di $CERT_DIR (aman, tidak dipakai)."
    echo "   Perbaiki penyebab di atas lalu jalankan ulang skrip ini."
    (cd "$PROXY_DIR" && docker compose up -d) || true
    exit 1
fi

hr "7. Jalankan ulang reverse proxy & validasi config"
(cd "$PROXY_DIR" && docker compose up -d --force-recreate) || exit 1
sleep 3
docker exec reverse-proxy nginx -t 2>&1 || true

hr "8. Uji HTTPS"
curl -s -o /dev/null -w "  https://%{http_code}  %{url_effective}\n" "https://$DOMAIN/" || true
curl -s -o /dev/null -w "  http  -> %{http_code} (harus 301) %{redirect_url}\n" "http://$DOMAIN/" || true
echo
echo "Selesai. Setelah HTTPS berjalan, ubah di attendapp/.env dan"
echo "app-laravel-docker/.env.docker:"
echo "  APP_URL=https://$DOMAIN"
echo "  APP_FORCE_HTTPS=true"
echo "lalu: cd app-laravel-docker && docker compose up -d --force-recreate app"
