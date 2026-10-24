#!/usr/bin/env bash
#
# Uji semantik file locking Linux, untuk dibandingkan langsung dengan
# windows/lock-probe.ps1.
#
#   lock-probe.sh <port> [path-step-summary]
#
# Dijalankan sebagai stage terakhir, karena eksperimen A sengaja menimpa index.html
# rilis yang sedang aktif. Tidak ada stage lain sesudahnya yang bergantung pada isi itu.
#
# Inti yang diuji: di Linux, nama file dan isi file adalah dua hal berbeda. Menghapus
# nama (unlink) tidak menyentuh inode, dan proses yang masih memegang file descriptor
# tetap membaca isi lama. Itulah alasan deploy di Linux boleh menimpa apa saja.

set -euo pipefail

PORT="${1:?usage: lock-probe.sh <port> [path-step-summary]}"

# Script ini dijalankan lewat sudo, karena harus menulis ke folder rilis milik root.
# sudo mereset environment, jadi GITHUB_STEP_SUMMARY tidak ikut terbawa dan path-nya
# diterima sebagai argumen. Lebih eksplisit daripada bergantung pada `sudo -E`, yang
# bisa ditolak tergantung konfigurasi sudoers.
SUMMARY="${2:-${GITHUB_STEP_SUMMARY:-}}"

ROOT="${DEMO_ROOT:-/var/www/demo}"
CURRENT="${ROOT}/current"
URL="http://localhost:${PORT}/"

# Hasil tiap eksperimen dikumpulkan sebagai baris tabel markdown, lalu ditulis sekali
# ke step summary di akhir. Lebih enak dibaca saat demo daripada men-scroll log.
rows=()

row() { rows+=("| ${1} | ${2} | ${3} |"); }

echo "=============================================="
echo " lock probe: Linux"
echo "=============================================="

# ---------------------------------------------------------------------------------
# Eksperimen A: timpa file yang sedang dilayani web server
# ---------------------------------------------------------------------------------
# Tidak diassert keras. Yang menarik di sini bukan lulus atau tidak, tapi perbandingan
# apa adanya dengan hasil runner Windows di job sebelahnya.
echo
echo "--- A: timpa index.html yang sedang dilayani nginx ---"

target="$(readlink -f "${CURRENT}")/index.html"

# Minta satu request dulu, supaya file benar-benar sudah pernah dibuka nginx dan bukan
# file yang belum tersentuh. Tanpa langkah ini eksperimennya tidak menguji apa pun.
# Yang dilaporkan cuma ukuran response, bukan isinya, supaya script ini tidak terikat
# pada struktur HTML aplikasi.
before="$(curl -fsS "${URL}" | wc -c | tr -d ' ')"
echo "sebelum: ${before} byte"

marker="lock-probe-$$"
if printf '<!doctype html><p>%s</p>\n' "${marker}" > "${target}" 2>/dev/null; then
  echo "tulis: BERHASIL"
  # Isi baru harus langsung terlihat. nginx membuka ulang file tiap request dan
  # open_file_cache tidak dinyalakan, jadi tidak ada lapisan cache di antaranya.
  if curl -fsS "${URL}" | grep -qF "${marker}"; then
    echo "request berikutnya: isi BARU"
    row "A. Timpa file yang sedang dilayani" "berhasil" "isi baru langsung terlihat"
  else
    echo "request berikutnya: masih isi LAMA"
    row "A. Timpa file yang sedang dilayani" "berhasil" "tapi response masih isi lama"
  fi
else
  echo "tulis: GAGAL"
  row "A. Timpa file yang sedang dilayani" "gagal" "penulisan ditolak"
fi

# ---------------------------------------------------------------------------------
# Eksperimen B: timpa dan hapus file yang handle-nya dipegang proses lain
# ---------------------------------------------------------------------------------
# Dua sub-eksperimen yang sama persis dengan sisi Windows, dengan label baris yang sama
# juga, supaya dua tabel summary bisa dibaca berdampingan.
#
# Ini perbedaan OS yang deterministik, jadi di sini boleh gagal keras. Kalau eksperimen
# ini tidak berperilaku seperti yang diharapkan, premis demonya salah, dan lebih baik
# pipeline-nya merah daripada klaimnya dibawa ke interview tanpa bukti.
echo
echo "--- B: timpa dan hapus file yang handle-nya dipegang ---"

scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT
held="${scratch}/held.txt"
echo "isi-asli" > "${held}"

# fd 9 memegang file ini sampai ditutup di bawah. Inilah padanan terdekat dari
# FileStream yang dibuka dengan FileShare.None di sisi Windows, bedanya di Linux tidak
# ada cara meminta akses eksklusif semacam itu untuk operasi filesystem biasa.
exec 9< "${held}"

# --- B1: timpa selagi fd terbuka. Harus berhasil. ---
if printf 'isi-baru\n' > "${held}"; then
  echo "timpa: BERHASIL, tidak ada yang memblokir"
  row "B. Timpa file yang handle-nya dipegang" "berhasil" "tidak ada akses eksklusif di Linux"
else
  echo "timpa: GAGAL, tidak diharapkan di Linux" >&2
  exit 1
fi

# --- B2: hapus selagi fd terbuka. Juga harus berhasil. ---
# Ini kontras paling tajam dengan Windows, di mana dua-duanya ditolak dengan IOException.
if rm "${held}"; then
  echo "hapus: BERHASIL, nama hilang dari direktori"
else
  echo "hapus: GAGAL, tidak diharapkan di Linux" >&2
  exit 1
fi

[[ ! -e "${held}" ]] || { echo "file seharusnya sudah tidak punya nama" >&2; exit 1; }

# Inode-nya belum dibebaskan, karena masih ada yang memegang referensi. Pembacaan lewat
# fd 9 tetap berhasil walaupun nama file-nya sudah tidak ada. Dibaca ulang dari offset 0,
# karena fd ini belum pernah dibaca sejak dibuka.
still="$(cat <&9)"
exec 9<&-

if [[ -n "${still}" ]]; then
  echo "baca lewat fd setelah hapus: masih berhasil (\"${still}\")"
  row "B. Hapus file yang handle-nya dipegang" "berhasil" "pemegang fd tetap bisa membaca inode"
else
  echo "baca lewat fd setelah hapus: tidak terduga, isinya kosong" >&2
  exit 1
fi

# ---------------------------------------------------------------------------------
# Ringkasan
# ---------------------------------------------------------------------------------
if [[ -n "${SUMMARY}" ]]; then
  {
    echo "### Lock probe: Linux"
    echo
    echo "| Eksperimen | Hasil | Catatan |"
    echo "| --- | --- | --- |"
    printf '%s\n' "${rows[@]}"
    echo
    echo "Di Linux nama file dan inode terpisah. Menghapus atau menimpa file yang sedang"
    echo "dipakai selalu diizinkan, dan proses yang sudah memegang file descriptor tidak"
    echo "terganggu. Karena itu deploy di Linux tidak perlu maintenance window."
  } >> "${SUMMARY}"
fi

echo
echo "==> lock probe Linux selesai"
