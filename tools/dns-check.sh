#!/usr/bin/env bash
# =============================================================================
# dns-check.sh - Diagnosa DNS untuk domain/subdomain sebelum pasang SSL
#
# Jalankan di VPS (atau laptop Linux/WSL) :
#   bash tools/dns-check.sh attd.kovcc.web.id
#
# Yang diperiksa:
#   1. Server NS (nameserver) yang melayani domain
#   2. SOA: apakah zone-nya benar-benar hidup di NS tersebut
#   3. A record dari NS authoritative (sumber kebenaran) vs resolver publik
#   4. Status jawaban: NOERROR / NXDOMAIN / SERVFAIL  (+ artinya)
#   5. Jejak delegasi dari TLD (dig +trace) - opsional
#
# Catatan: skrip ini hanya MEMBACA DNS. Tidak mengubah apa pun.
# Butuh paket `dnsutils` (Debian/Ubuntu):  sudo apt-get install -y dnsutils
# =============================================================================
set -u

DOMAIN="${1:-}"
if [ -z "$DOMAIN" ]; then
    echo "Penggunaan: bash tools/dns-check.sh <domain>"
    echo "Contoh    : bash tools/dns-check.sh attd.kovcc.web.id"
    exit 1
fi

hr() { printf '\n=============== %s ===============\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

if ! have dig; then
    echo "!! 'dig' tidak ada. Pasang dulu:  sudo apt-get install -y dnsutils"
    echo "   Alternatif cepat:  nslookup $DOMAIN 8.8.8.8"
    exit 1
fi

# Domain registrable: ambil 3 label terakhir untuk domain .xxx.yy (mis. web.id)
# atau 2 label untuk domain biasa (mis. contoh.com).
BASE_DOMAIN="$(echo "$DOMAIN" | awk -F. '{ if (NF>=3) printf "%s.%s.%s\n", $(NF-2), $(NF-1), $NF; else print $0 }')"

hr "0. Info"
echo "Domain       : $DOMAIN"
echo "Base domain  : $BASE_DOMAIN"
echo "Waktu        : $(date -u)"

hr "1. Nameserver (NS) domain"
NS_LIST="$(dig +short NS "$BASE_DOMAIN" 2>/dev/null || true)"
if [ -z "$NS_LIST" ]; then
    echo "  (tidak ada NS yang dikembalikan)"
else
    echo "$NS_LIST" | sed 's/^/  /'
fi

hr "2. SOA dari NS authoritative (apakah zone hidup?)"
FIRST_NS="$(echo "$NS_LIST" | head -1 | sed 's/\.$//')"
if [ -n "$FIRST_NS" ]; then
    echo "  Query langsung ke: $FIRST_NS"
    dig +noall +answer SOA "$BASE_DOMAIN" "@$FIRST_NS" 2>&1 | sed 's/^/  /' || true
    dig +noall +comments SOA "$BASE_DOMAIN" "@$FIRST_NS" 2>&1 | grep -iE 'status:' | sed 's/^/  /' || true
else
    echo "  Tidak bisa menentukan NS, lewati."
fi

hr "3. A record subdomain"
echo "  -- dari NS authoritative ($FIRST_NS):"
if [ -n "$FIRST_NS" ]; then
    dig +noall +answer A "$DOMAIN" "@$FIRST_NS" 2>&1 | sed 's/^/     /' || true
    dig +noall +comments A "$DOMAIN" "@$FIRST_NS" 2>&1 | grep -iE 'status:' | sed 's/^/     /' || true
fi
for r in 1.1.1.1 8.8.8.8; do
    echo "  -- dari resolver publik $r:"
    dig +noall +answer A "$DOMAIN" "@$r" 2>&1 | sed 's/^/     /' || true
    dig +noall +comments A "$DOMAIN" "@$r" 2>&1 | grep -iE 'status:' | sed 's/^/     /' || true
done

hr "4. Terjemahan status"
STATUS_PUBLIC="$(dig +noall +comments A "$DOMAIN" "@1.1.1.1" 2>/dev/null | grep -oiE 'status: [A-Z]+' | awk '{print $2}' | head -1)"
echo "  status dari Cloudflare (1.1.1.1): ${STATUS_PUBLIC:-<tidak ada jawaban>}"
case "${STATUS_PUBLIC:-}" in
    NOERROR)
        echo "  -> DOMAIN OK. Kalau A record kosong, periksa nama record-nya"
        echo "     (kolom Name biasanya cukup label: 'attd')."
        ;;
    NXDOMAIN)
        echo "  -> Domain/record TIDAK ADA. NS hidup, tetapi record 'attd' belum dibuat"
        echo "     atau NAMA record salah (mis. diisi 'attd.kovcc.web.id' sehingga"
        echo "     menjadi 'attd.kovcc.web.id.kovcc.web.id')."
        ;;
    SERVFAIL)
        echo "  -> SERVFAIL = nameserver authoritative GAGAL menjawab."
        echo "     Ini BUKAN masalah propagasi biasa (propagasi menghasilkan NOERROR"
        echo "     atau NXDOMAIN). Penyebab umum:"
        echo "       a) domain BARU: zone belum dibuat/diaktifkan di DNS provider -> tunggu"
        echo "          aktivasi (bisa beberapa jam) atau hubungi support idwebhost;"
        echo "       b) nameserver domain belum diarahkan ke NS provider (NS belum"
        echo "          terdaftar di registry .id) -> cek menu domain/nameserver;"
        echo "       c) zone file rusak di provider (mis. record bentrok/CNAME ganda)."
        ;;
    *)
        echo "  -> Tidak ada jawaban dari resolver. Cek koneksi internet/DNS lokal:"
        echo "     cat /etc/resolv.conf ; dig +short NS 1.1.1.1"
        ;;
esac

hr "5. Jejak delegasi (ringkas)"
dig +trace "$DOMAIN" 2>/dev/null | grep -E '^[a-z0-9_.-]+\.|^;; Received|SERVFAIL|NXDOMAIN' | tail -18 | sed 's/^/  /' || true

hr "6. Rekomendasi tindakan"
cat <<'EOF'
  Urutan cek yang paling cepat:
    1. Buka panel DNS provider (idwebhost -> DNS Zone Editor):
       - Type: A | Name: attd | Value: IP_VPS | TTL: 14400
    2. Simpan, lalu tunggu 5-30 menit.
    3. Jalankan ulang skrip ini. Target: status = NOERROR dan A record = IP VPS.
    4. Bila masih SERVFAIL setelah beberapa jam:
       - pastikan nameserver domain memang nameserver idwebhost (menu Domain),
       - hubungi support idwebhost: "zone kovcc.web.id mengembalikan SERVFAIL".
    5. Setelah NOERROR + IP benar, baru jalankan tools/enable-https.sh.

  Catatan: 8.8.8.8/1.1.1.1 punya cache negatif. Untuk uji "sumber kebenaran"
  selalu tanyakan langsung ke NS authoritative (bagian 2 & 3 di atas).
EOF
