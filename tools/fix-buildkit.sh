#!/usr/bin/env bash
# =============================================================================
# fix-buildkit.sh - Perbaiki build Docker yang gagal karena cache BuildKit rusak
#
# Gejala yang ditangani:
#   failed to commit <snapshot> to <snapshot> during finalize:
#   failed to stat active key during commit: snapshot ... does not exist: not found
#   failed to solve: ... snapshot ... does not exist: not found
#
# Artinya: metadata snapshot BuildKit/containerd TIDAK sinkron dengan isinya
# (biasanya setelah build dibatalkan, disk penuh, container/prune bersamaan,
# atau update Docker daemon). Ini BUKAN masalah Dockerfile.
#
# Jalankan di VPS dari root repo docker-ecosystem:
#   cd ~/projects/docker-ecosystem
#   bash tools/fix-buildkit.sh            # diagnosa + bersihkan cache build
#   bash tools/fix-buildkit.sh --restart  # + restart Docker daemon (perlu sudo)
#   bash tools/fix-buildkit.sh --legacy   # pakai builder lama (BUKAN containerd)
#
# Catatan: `docker builder prune` HANYA menghapus cache build. Image dan
# container yang sedang berjalan TIDAK disentuh.
# =============================================================================
set -u

RESTART=0
LEGACY=0
for arg in "$@"; do
    case "$arg" in
        --restart) RESTART=1 ;;
        --legacy)  LEGACY=1 ;;
        -h|--help)
            awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"
            exit 0
            ;;
        *) echo "Argumen tidak dikenal: $arg (pakai --help)"; exit 2 ;;
    esac
done

hr() { printf '\n=============== %s ===============\n' "$1"; }

if ! docker info >/dev/null 2>&1; then
    if sudo -n docker info >/dev/null 2>&1; then
        DOCKER="sudo -n docker"
    else
        echo "ERROR: tidak bisa mengakses Docker (user $(whoami))."
        echo "       Perbaikan: sudo usermod -aG docker $(whoami) ; logout lalu login."
        exit 1
    fi
else
    DOCKER="docker"
fi

if [ "$RESTART" = "1" ]; then
    hr "0. Restart Docker daemon (diminta lewat --restart)"
    echo "  Container dengan restart policy akan hidup lagi otomatis."
    sudo -n systemctl restart docker 2>/dev/null \
        || echo "  !! tidak bisa restart otomatis (perlu sudo tanpa password). Jalankan manual: sudo systemctl restart docker"
    for _i in $(seq 1 30); do
        $DOCKER info >/dev/null 2>&1 && break
        sleep 1
    done
fi

hr "1. Informasi Docker & penyimpanan"
$DOCKER version --format '  client={{.Client.Version}} server={{.Server.Version}}' 2>/dev/null
echo "  driver penyimpanan : $($DOCKER info -f '{{.Driver}}' 2>/dev/null)"
echo "  containerd snapshotter: $($DOCKER info -f '{{range .DriverStatus}}{{.}}{{"\n"}}{{end}}' 2>/dev/null | tr '\n' ' ')"
$DOCKER system df 2>/dev/null | sed 's/^/  /'
echo "  Disk /var/lib/docker:"
df -h /var/lib/docker 2>/dev/null | sed 's/^/    /'
INODE=$(df -i /var/lib/docker 2>/dev/null | awk 'NR==2{print $5}')
[ -n "${INODE:-}" ] && echo "    inode terpakai: $INODE"

hr "2. Bersihkan cache build (image & container TIDAK dihapus)"
echo "  -> $DOCKER builder prune -af"
$DOCKER builder prune -af 2>&1 | sed 's/^/     /' || echo "     (builder prune gagal, lanjut)"
if $DOCKER buildx version >/dev/null 2>&1; then
    echo "  -> $DOCKER buildx prune -af"
    $DOCKER buildx prune -af 2>&1 | sed 's/^/     /' || echo "     (buildx prune gagal, lanjut)"
fi

hr "3. Uji build kecil (memastikan snapshotter sehat)"
TMPD=$(mktemp -d 2>/dev/null || echo "/tmp/uji-build-$$")
mkdir -p "$TMPD"
cat > "$TMPD/Dockerfile" <<'EOF'
FROM alpine:3.20
RUN echo "uji buildkit ok" > /tmp/uji.txt
COPY Dockerfile /tmp/Dockerfile.salin
EOF
LOG_UJI="$TMPD/build.log"
if [ "$LEGACY" = "1" ]; then
    echo "  (mode --legacy: DOCKER_BUILDKIT=0)"
    ( cd "$TMPD" && DOCKER_BUILDKIT=0 $DOCKER build -t uji-buildkit:lokal . ) > "$LOG_UJI" 2>&1
else
    ( cd "$TMPD" && $DOCKER build -t uji-buildkit:lokal . ) > "$LOG_UJI" 2>&1
fi
RC=$?
tail -15 "$LOG_UJI" | sed 's/^/     /'
rm -rf "$TMPD"

hr "4. Hasil"
if [ "$RC" = "0" ]; then
    echo "  OK: build berhasil -> cache BuildKit sudah sehat."
    echo "  Lanjutkan (manual, di VPS):"
    echo "    cd app-laravel-docker && docker compose up -d --build --force-recreate app laravel-nginx"
    $DOCKER rmi uji-buildkit:lokal >/dev/null 2>&1 || true
    exit 0
fi

echo "  GAGAL: build masih error -> cache/metadata BuildKit belum bersih."
echo
echo "  Langkah berikutnya (berurutan, hentikan bila sudah berhasil):"
echo "    1) Restart Docker daemon:"
echo "         sudo systemctl restart docker"
echo "       lalu ulangi: bash tools/fix-buildkit.sh"
echo "    2) Kalau masih gagal, matikan containerd image store"
echo "       (Docker 23+ menyimpannya sebagai snapshot; bug 'snapshot does not exist'"
echo "        sering hilang dengan kembali ke image store klasik):"
echo "         sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.bak 2>/dev/null"
echo "         # tambahkan/ubah: { \"features\": { \"containerd-snapshotter\": false } }"
echo "         sudo systemctl restart docker"
echo "       Setelah itu SEMUA image perlu di-pull ulang:"
echo "         cd ~/projects/docker-ecosystem"
echo "         ( cd app-laravel-docker && docker compose up -d --build --force-recreate app laravel-nginx )"
echo "    3) Pakai builder lama sekali untuk membangun ulang image:"
echo "         bash tools/fix-buildkit.sh --legacy"
echo "    4) Kalau disk/inode penuh, bersihkan dulu:"
echo "         docker image prune -f ; docker builder prune -af ; df -h"
exit 1
