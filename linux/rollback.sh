#!/usr/bin/env bash
#
# Kembalikan symlink `current` ke rilis sebelum ini.
#
#   rollback.sh
#
# Di Linux rollback hanya butuh satu rename: folder rilis lama masih utuh di disk dan
# tidak pernah ditimpa, jadi tidak ada yang perlu direstore. Bandingkan dengan
# windows/rollback.ps1, yang masih harus me-recycle app pool sesudahnya.
#
# Idempotent: file `previous` dihapus setelah dipakai, jadi menjalankan script ini dua
# kali berturut-turut bukan bolak-balik antar dua rilis, melainkan no-op yang eksplisit.

set -euo pipefail

ROOT="${DEMO_ROOT:-/var/www/demo}"
CURRENT="${ROOT}/current"
PREVIOUS="${ROOT}/previous"

# --- 1. Cek apakah ada tujuan rollback --------------------------------------------
if [[ ! -s "${PREVIOUS}" ]]; then
  echo "==> tidak ada rilis sebelumnya yang tercatat, tidak ada yang perlu dirollback"
  exit 0
fi

TARGET="$(cat "${PREVIOUS}")"

# --- 2. Validasi tujuan masih ada di disk -----------------------------------------
# Rilis bisa sudah terpangkas, atau path-nya salah. Lebih baik gagal keras di sini
# daripada mengarahkan symlink ke folder yang tidak ada dan menghasilkan 404.
if [[ ! -d "${TARGET}" ]]; then
  echo "rilis tujuan rollback tidak ada di disk: ${TARGET}" >&2
  exit 1
fi

echo "==> rollback dari $(readlink -f "${CURRENT}" 2>/dev/null || echo '(belum ada)')"
echo "               ke ${TARGET}"

# --- 3. Swap symlink, cara yang sama persis dengan deploy -------------------------
# Rollback bukan jalur kode khusus, cuma deploy ke arah sebaliknya. Memakai mekanisme
# yang identik berarti rollback tidak bisa busuk tanpa deploy ikut busuk juga.
ln -sfn "${TARGET}" "${CURRENT}.tmp"
mv -T "${CURRENT}.tmp" "${CURRENT}"

# --- 4. Habiskan catatan rollback -------------------------------------------------
# Dihapus, bukan ditukar, supaya rollback kedua jadi no-op dan bukan toggle.
rm -f "${PREVIOUS}"

echo "==> current -> $(readlink -f "${CURRENT}")"
echo "==> rollback selesai"
