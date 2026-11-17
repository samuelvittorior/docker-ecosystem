#!/usr/bin/env bash
# =============================================================================
# renew-https.sh - Perpanjang sertifikat Let's Encrypt TANPA downtime
#
# Jalankan di VPS sebagai ROOT (certbot membaca /etc/letsencrypt):
#   cd ~/projects/docker-ecosystem
#   sudo bash tools/renew-https.sh              # perpanjang yang sudah jatuh tempo
#   sudo bash tools/renew-https.sh --dry-run    # uji saja, tidak mengubah apa pun
#
# Cara kerja:
#   1. certbot renew (mode webroot) -> nginx tetap hidup, tidak ada downtime
#      (folder challenge: reverse-proxy-docker/nginx/certbot)
#   2. salin ulang sertifikat yang berubah ke reverse-proxy-docker/nginx/certs/
#   3. `nginx -s reload` -> sertifikat baru langsung dipakai
#
# Sertifikat Let's Encrypt berlaku 90 hari; certbot hanya memperpanjang bila
# sisa masa berlaku < 30 hari, jadi aman dijalankan sesering apa pun (mis.
# harian). Pasang di cron -> lihat README bagian 'Perpanjangan otomatis'.
# =============================================================================
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROXY_DIR="$ROOT_DIR/reverse-proxy-docker"
CERT_DIR="$PROXY_DIR/nginx/certs"
WEBROOT="$PROXY_DIR/nginx/certbot"
DRY_RUN=0

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help)
            echo "Penggunaan: sudo bash tools/renew-https.sh [--dry-run]"
            exit 0 ;;
        *)
            echo "Argumen tidak dikenal: $arg"
            echo "Penggunaan: sudo bash tools/renew-https.sh [--dry-run]"
            exit 1 ;;
    esac
done

hr() { printf '\n=============== %s ===============\n' "$1"; }

hr "0. Pemeriksaan"
if ! command -v certbot >/dev/null 2>&1; then
    echo "!! certbot belum ada. Jalankan: sudo apt-get install -y certbot"
    exit 1
fi
if [ "$(id -u)" != "0" ]; then
    echo "!! Jalankan sebagai root:  sudo bash tools/renew-https.sh"
    exit 1
fi
mkdir -p "$WEBROOT/.well-known/acme-challenge" "$CERT_DIR"
echo "Webroot   : $WEBROOT"
echo "Cert dir  : $CERT_DIR"
echo "Dry run   : $DRY_RUN"

hr "1. certbot renew (webroot)"
RENEW_ARGS="--webroot -w $WEBROOT --quiet"
if [ "$DRY_RUN" = "1" ]; then
    RENEW_ARGS="$RENEW_ARGS --dry-run"
    echo "  (dry-run: tidak ada sertifikat yang benar-benar diperbarui)"
fi
# certbot hanya memperpanjang sertifikat yang sisa masa berlakunya < 30 hari.
# shellcheck disable=SC2086
certbot renew $RENEW_ARGS || {
    echo "!! certbot renew GAGAL. Periksa:"
    echo "   - port 80 terbuka?          sudo ufw status | grep 80"
    echo "   - proxy hidup & webroot?    docker exec reverse-proxy ls /var/www/certbot/.well-known"
    echo "   - log certbot:              tail -50 /var/log/letsencrypt/letsencrypt.log"
    exit 1
}
echo "  certbot selesai."

hr "2. Salin sertifikat yang diperbarui ke $CERT_DIR"
# Hanya sertifikat yang SUDAH dipakai nginx (punya file .crt di CERT_DIR) yang
# disalin -- supaya sertifikat milik aplikasi lain tidak ikut campur.
COPIED=0
for crt in "$CERT_DIR"/*.crt; do
    [ -f "$crt" ] || continue
    name="$(basename "$crt" .crt)"
    live="/etc/letsencrypt/live/$name"
    if [ ! -f "$live/fullchain.pem" ]; then
        echo "  ! $name: tidak ada di $live (lewati)"
        continue
    fi
    if [ "$DRY_RUN" = "1" ]; then
        echo "  (dry-run) akan menyalin: $name"
        continue
    fi
    # Bandingkan dulu: hanya salin bila isinya berubah.
    if cmp -s "$live/fullchain.pem" "$crt"; then
        echo "  = $name: belum berubah"
        continue
    fi
    cp "$live/fullchain.pem" "$CERT_DIR/$name.crt"
    cp "$live/privkey.pem"   "$CERT_DIR/$name.key"
    chmod 644 "$CERT_DIR/$name.crt"
    chmod 640 "$CERT_DIR/$name.key"
    echo "  + $name: sertifikat diperbarui"
    COPIED=$((COPIED + 1))
done

hr "3. Muat ulang nginx (tanpa downtime)"
if [ "$DRY_RUN" = "1" ]; then
    echo "  (dry-run) nginx tidak di-reload."
elif [ "$COPIED" = "0" ]; then
    echo "  Tidak ada sertifikat yang berubah -> nginx tidak perlu di-reload."
else
    # `nginx -s reload` membaca ulang sertifikat TANPA memutus koneksi aktif,
    # jadi pengguna yang sedang memakai aplikasi tidak terganggu.
    if docker exec reverse-proxy nginx -t 2>&1; then
        docker exec reverse-proxy nginx -s reload 2>&1 && echo "  nginx di-reload."
    else
        echo "!! Config nginx tidak valid -> reload dibatalkan (proxy tetap jalan)."
        exit 1
    fi
fi

hr "4. Masa berlaku sertifikat"
for crt in "$CERT_DIR"/*.crt; do
    [ -f "$crt" ] || continue
    name="$(basename "$crt" .crt)"
    END="$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | cut -d= -f2 || true)"
    echo "  $name -> berakhir: ${END:-<tidak terbaca>}"
done

echo
echo "Selesai."
if [ "$DRY_RUN" = "1" ]; then
    echo "Ini hanya uji (dry-run). Untuk perpanjangan sungguhan:"
    echo "  sudo bash tools/renew-https.sh"
fi

