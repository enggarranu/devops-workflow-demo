#!/usr/bin/env bash
#
# Smoke test satu rilis yang sedang dilayani nginx.
#
#   smoke-test.sh <url> <harus-ada> [tidak-boleh-ada]
#
# Argumen ketiga itulah yang membuat test ini bermakna setelah rollback. Mengecek
# "build lama muncul" saja belum cukup, karena bisa jadi dua rilis tercampur di satu
# folder. Mengecek sekaligus bahwa build baru sudah TIDAK muncul membuktikan pointer
# benar-benar berpindah.

set -euo pipefail

URL="${1:?usage: smoke-test.sh <url> <harus-ada> [tidak-boleh-ada]}"
MUST_CONTAIN="${2:?usage: smoke-test.sh <url> <harus-ada> [tidak-boleh-ada]}"
MUST_NOT_CONTAIN="${3:-}"

ATTEMPTS=5
DELAY=2

echo "==> smoke test ${URL}"
echo "    harus ada        : ${MUST_CONTAIN}"
[[ -n "${MUST_NOT_CONTAIN}" ]] && echo "    tidak boleh ada  : ${MUST_NOT_CONTAIN}"

# Retry bukan kosmetik. nginx baru selesai reload, atau swap symlink baru saja terjadi,
# dan tanpa retry test ini kadang gagal karena balapan waktu, bukan karena deploy-nya
# salah. Flaky-nya akan muncul tepat saat demo.
body=''
for attempt in $(seq 1 "${ATTEMPTS}"); do
  # -f membuat curl exit non-zero untuk status 4xx/5xx, jadi HTTP error ikut tertangkap
  # dan tidak diam-diam lolos sebagai body kosong.
  # -F mencocokkan sebagai teks biasa, bukan regex. Build id mengandung titik, dan
  # tanpa -F titik itu cocok dengan karakter apa pun. Sekaligus menjaga script ini
  # setara persis dengan .Contains() di windows/smoke-test.ps1.
  if body="$(curl -fsS --max-time 10 "${URL}")" && grep -qF -- "${MUST_CONTAIN}" <<< "${body}"; then
    echo "    percobaan ${attempt}: cocok"
    break
  fi
  if [[ "${attempt}" -eq "${ATTEMPTS}" ]]; then
    echo "GAGAL: setelah ${ATTEMPTS} percobaan, \"${MUST_CONTAIN}\" tidak ada di response" >&2
    echo "--- response terakhir ---" >&2
    echo "${body:-(kosong)}" >&2
    exit 1
  fi
  echo "    percobaan ${attempt}: belum cocok, coba lagi dalam ${DELAY}s"
  sleep "${DELAY}"
done

# Pengecekan negatif tidak di-retry. Kalau string yang seharusnya hilang masih ada,
# menunggu tidak akan mengubah apa pun, dan rollback-nya memang gagal.
if [[ -n "${MUST_NOT_CONTAIN}" ]] && grep -qF -- "${MUST_NOT_CONTAIN}" <<< "${body}"; then
  echo "GAGAL: \"${MUST_NOT_CONTAIN}\" seharusnya sudah tidak dilayani, tapi masih ada" >&2
  echo "--- response ---" >&2
  echo "${body}" >&2
  exit 1
fi

echo "==> smoke test lolos"
