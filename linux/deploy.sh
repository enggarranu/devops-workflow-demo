#!/usr/bin/env bash
#
# Deploy satu rilis baru ke nginx, lalu arahkan symlink `current` ke rilis itu.
#
#   deploy.sh <build-id> <paket.tar.gz>
#
# Strategi: rilis immutable + swap pointer. Folder rilis yang sudah jadi tidak pernah
# disentuh lagi, jadi tidak ada kemungkinan menimpa file yang sedang dilayani nginx.
# Padanannya di Windows adalah mengganti physicalPath site (lihat windows/deploy.ps1).
#
# DEMO_ROOT bisa dioverride untuk tes lokal tanpa sudo, misalnya:
#   DEMO_ROOT=/tmp/demo-root ./linux/deploy.sh 1-abc app.tar.gz

set -euo pipefail

BUILD_ID="${1:?usage: deploy.sh <build-id> <paket.tar.gz>}"
PACKAGE="${2:?usage: deploy.sh <build-id> <paket.tar.gz>}"

ROOT="${DEMO_ROOT:-/var/www/demo}"
RELEASES="${ROOT}/releases"
CURRENT="${ROOT}/current"
PREVIOUS="${ROOT}/previous"
KEEP=5   # jumlah rilis yang disimpan, sisanya dipangkas

[[ -f "${PACKAGE}" ]] || { echo "paket tidak ada: ${PACKAGE}" >&2; exit 1; }

# --- 1. Siapkan struktur direktori -------------------------------------------------
# mkdir -p aman dijalankan berulang, jadi script ini tidak perlu tahu apakah ini
# deploy pertama atau yang kesepuluh.
mkdir -p "${RELEASES}"

# --- 2. Tentukan nomor rilis berikutnya --------------------------------------------
# Nomor berurut dan zero-padded supaya folder-nya terbaca rapi dan mudah diurutkan.
# `|| true` dipasang karena grep mengembalikan exit 1 kalau belum ada rilis sama
# sekali, dan `set -e` akan mematikan script di situ.
LAST="$(ls -1 "${RELEASES}" 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tail -1 || true)"
NEXT="$(printf '%04d' "$(( ${LAST:-0} + 1 ))")"
RELEASE_DIR="${RELEASES}/${NEXT}"

echo "==> rilis ${NEXT}  (build ${BUILD_ID})"

# --- 3. Bongkar paket ke folder rilis baru -----------------------------------------
mkdir -p "${RELEASE_DIR}"
tar -xzf "${PACKAGE}" -C "${RELEASE_DIR}"

# --- 4. Cap build id ke dalam artefak ----------------------------------------------
# Ini yang membuat tiap rilis bisa dibedakan dari luar lewat HTTP, sehingga smoke test
# setelah rollback bisa membuktikan isi yang dilayani benar-benar berubah.
find "${RELEASE_DIR}" -type f -name '*.html' -print0 \
  | xargs -0 --no-run-if-empty sed -i "s/__BUILD_ID__/${BUILD_ID}/g"

grep -q "${BUILD_ID}" "${RELEASE_DIR}/index.html" \
  || { echo "build id gagal dicap ke index.html" >&2; exit 1; }

# --- 5. Catat rilis yang sedang aktif sebagai tujuan rollback ----------------------
# Dicatat SEBELUM swap, selagi `current` masih menunjuk rilis lama. readlink -f dipakai
# supaya yang tersimpan path absolut, bukan path relatif yang bisa salah arti nanti.
if [[ -L "${CURRENT}" ]]; then
  readlink -f "${CURRENT}" > "${PREVIOUS}"
  echo "    rollback target dicatat: $(cat "${PREVIOUS}")"
else
  # Deploy pertama: belum ada ke mana harus rollback. File previous dikosongkan,
  # bukan dibiarkan berisi nilai lama yang menyesatkan.
  : > "${PREVIOUS}"
  echo "    deploy pertama, belum ada rollback target"
fi

# --- 6. Swap symlink secara atomic -------------------------------------------------
# `ln -sfn` langsung ke `current` tidak atomic: ada jeda saat symlink lama sudah
# dihapus tapi yang baru belum ada, dan request yang masuk di jeda itu kena 404.
# Membuat symlink dengan nama sementara lalu `mv -T` membuat pergantiannya satu
# operasi rename tunggal di kernel, jadi tidak ada request yang melihat state kosong.
ln -sfn "${RELEASE_DIR}" "${CURRENT}.tmp"
mv -T "${CURRENT}.tmp" "${CURRENT}"

echo "==> current -> $(readlink -f "${CURRENT}")"

# --- 7. Pangkas rilis lama ---------------------------------------------------------
# Rilis yang masih jadi tujuan rollback tidak boleh ikut terhapus, jadi dilindungi
# eksplisit. KEEP=5 sudah jauh lebih besar dari kebutuhan, tapi pengecekan ini yang
# membuat script tetap benar kalau KEEP diturunkan jadi 2.
PROTECTED="$(cat "${PREVIOUS}" 2>/dev/null || true)"
ACTIVE="$(readlink -f "${CURRENT}")"

ls -1 "${RELEASES}" | grep -E '^[0-9]+$' | sort -n | head -n "-${KEEP}" | while read -r old; do
  old_path="${RELEASES}/${old}"
  if [[ "${old_path}" == "${ACTIVE}" || "${old_path}" == "${PROTECTED}" ]]; then
    continue
  fi
  echo "    pangkas rilis lama: ${old}"
  rm -rf "${old_path}"
done

echo "==> deploy selesai"
