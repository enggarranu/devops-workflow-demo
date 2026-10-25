#!/usr/bin/env bash
#
# Rakit halaman hasil, lalu commit dan push-nya ke repo.
#
#   push-result.sh <dir-artifact> <branch>
#
# Kenapa ini jadi script sendiri dan bukan beberapa baris di workflow: urusan
# perlombaan push butuh percobaan ulang, dan retry loop di dalam blok `run:`
# YAML jauh lebih sulit dibaca daripada di file bash biasa.
#
# Masalah yang diselesaikan: dua run bisa mencoba push ke branch yang sama.
# Yang kalah akan ditolak dengan "non-fast-forward". Penanganannya bukan
# memaksa push, tapi mengulang dari keadaan remote terbaru:
#
#   1. render  ->  commit  ->  git pull --rebase  ->  git push
#   2. kalau gagal: batalkan rebase, reset keras ke remote, rakit ULANG,
#      lalu coba lagi. Perakitan ulang itu yang penting, karena history.json
#      di remote mungkin sudah berisi run lain yang harus ikut terbawa.
#
# `render.py` idempotent, jadi perakitan ulang aman dan hasilnya sama.
# Sengaja tidak memakai --force: kalah lomba push bukan alasan menimpa commit
# orang lain.

set -euo pipefail

ARTIFACTS="${1:?usage: push-result.sh <dir-artifact> <branch>}"
BRANCH="${2:?usage: push-result.sh <dir-artifact> <branch>}"

OUT='docs/result'
MAX_ATTEMPT=3

# Identitas bot bawaan GitHub Actions, bukan identitas Anda. Jadi commit hasil
# generate terbaca jelas sebagai buatan CI di riwayat git.
git config user.name  'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'

for attempt in $(seq 1 "${MAX_ATTEMPT}"); do
  echo "==> percobaan ${attempt} dari ${MAX_ATTEMPT}"

  python3 publish/render.py \
    --artifacts "${ARTIFACTS}" \
    --template  publish/template.html \
    --out       "${OUT}"

  git add "${OUT}"

  # Tidak ada perubahan berarti run ini menghasilkan halaman yang identik,
  # misalnya saat re-run tanpa commit baru. Commit kosong tidak dibuat.
  if git diff --cached --quiet; then
    echo '==> halaman hasil tidak berubah, tidak ada yang perlu di-commit'
    exit 0
  fi

  # [skip ci] di akhir subject. Tanpa itu, push ini memicu workflow yang sama
  # dan jadi loop tak berujung: deploy -> publish -> push -> deploy.
  git commit -q -m "result page: build ${GITHUB_RUN_NUMBER} [skip ci]"

  # pull --rebase, bukan merge: riwayat branch tetap lurus dan commit hasil
  # generate tidak menambah commit merge tiap run.
  if git pull --rebase --quiet origin "${BRANCH}" \
     && git push --quiet origin "HEAD:${BRANCH}"; then
    echo "==> ter-push ke ${BRANCH}"
    exit 0
  fi

  echo "==> push kalah lomba atau rebase bentrok, mengulang dari remote terbaru" >&2

  # Rebase yang berhenti di tengah harus dibatalkan dulu, kalau tidak git
  # menolak semua perintah berikutnya. `|| true` karena mungkin saja tidak ada
  # rebase yang sedang jalan, dan itu bukan error.
  git rebase --abort 2>/dev/null || true
  git fetch --quiet origin "${BRANCH}"
  git reset --hard --quiet "origin/${BRANCH}"
done

echo "gagal push setelah ${MAX_ATTEMPT} percobaan" >&2
exit 1
