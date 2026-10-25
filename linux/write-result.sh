#!/usr/bin/env bash
#
# Catat hasil run ini sebagai satu file JSON, untuk dipublish job `publish`
# jadi halaman di GitHub Pages.
#
#   write-result.sh <file-json-keluaran>
#
# Script ini tidak mengubah apa pun. Dia hanya membaca keadaan nyata di runner
# setelah deploy, smoke test, dan rollback selesai, lalu menuliskannya.
#
# Dijalankan TANPA sudo supaya environment dari workflow (BUILD_V1, ROLLBACK_MS,
# dan kawan-kawannya) ikut terbawa. Satu-satunya yang butuh elevasi adalah
# membaca pointer rilis, dan itu dipanggil per perintah di bawah.
#
# Semua nilai dirakit lewat `jq -n --arg`, bukan string interpolation, supaya
# tidak ada nilai yang bisa merusak struktur JSON-nya. jq sudah terpasang di
# image ubuntu-latest. Alternatif tanpa dependensi: heredoc biasa, tapi itu
# pecah kalau salah satu nilai mengandung tanda kutip.

set -euo pipefail

OUT="${1:?usage: write-result.sh <file-json-keluaran>}"

ROOT="${DEMO_ROOT:-/var/www/demo}"
RELEASES="${ROOT}/releases"
CURRENT="${ROOT}/current"

# --- 1. Keadaan nyata di disk ------------------------------------------------
# Rilis yang SEDANG dilayani, dibaca dari pointer-nya, bukan ditebak dari nomor
# tertinggi. Setelah rollback nilainya memang bukan rilis terbaru, dan itu
# justru yang mau ditampilkan di halaman hasil.
RELEASE_ACTIVE="$(sudo readlink -f "${CURRENT}")"

# Rilis dengan nomor tertinggi adalah yang dibuat deploy terakhir di run ini.
RELEASE_LATEST_NUM="$(sudo ls -1 "${RELEASES}" | grep -E '^[0-9]+$' | sort -n | tail -1)"
RELEASE_DEPLOYED="${RELEASES}/${RELEASE_LATEST_NUM}"

# --- 2. Versi web server -----------------------------------------------------
# nginx -v menulis ke stderr, bukan stdout.
WEB_SERVER="$(nginx -v 2>&1 | sed 's/^nginx version: //')"

# lsb_release memberi nama rilis yang utuh. $ImageOS cuma "ubuntu24".
RUNNER_OS="$(lsb_release -ds 2>/dev/null || echo "${ImageOS:-unknown}")"

# --- 3. Rakit JSON -----------------------------------------------------------
jq -n \
  --arg platform         'linux' \
  --arg platform_label   'Linux' \
  --arg server_label     'nginx' \
  --arg runner_image     'ubuntu-latest' \
  --arg runner_os        "${RUNNER_OS}" \
  --arg web_server       "${WEB_SERVER}" \
  --arg build_id         "${BUILD_ID}" \
  --arg version          "${VERSION}" \
  --arg run_id           "${GITHUB_RUN_ID}" \
  --arg run_number       "${GITHUB_RUN_NUMBER}" \
  --arg run_attempt      "${GITHUB_RUN_ATTEMPT}" \
  --arg run_url          "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}" \
  --arg repo             "${GITHUB_REPOSITORY}" \
  --arg commit_sha       "${GITHUB_SHA}" \
  --arg commit_url       "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/commit/${GITHUB_SHA}" \
  --arg commit_subject   "$(git log -1 --pretty=%s)" \
  --arg deployed_at_utc  "${DEPLOY_AT}" \
  --arg deploy_method    'symlink swap' \
  --arg deploy_method_cmd 'ln -sfn <rilis> current.tmp  &&  mv -T current.tmp current' \
  --arg pointer          "${CURRENT}" \
  --arg release_deployed "${RELEASE_DEPLOYED}" \
  --arg release_active   "${RELEASE_ACTIVE}" \
  --arg build_v1         "${BUILD_V1}" \
  --arg build_v2         "${BUILD_V2}" \
  --arg smoke_url        "http://localhost:${APP_PORT}/" \
  --arg smoke_tool       'curl -fsS + grep -qF' \
  --argjson rb_ops       1 \
  --argjson rb_ms        "${ROLLBACK_MS}" \
  '{
     platform: $platform,
     platform_label: $platform_label,
     server_label: $server_label,
     runner_image: $runner_image,
     runner_os: $runner_os,
     web_server: $web_server,
     build_id: $build_id,
     version: $version,
     run_id: $run_id,
     run_number: $run_number,
     run_attempt: $run_attempt,
     run_url: $run_url,
     repo: $repo,
     commit_sha: $commit_sha,
     commit_url: $commit_url,
     commit_subject: $commit_subject,
     deployed_at_utc: $deployed_at_utc,
     deploy_method: $deploy_method,
     deploy_method_cmd: $deploy_method_cmd,
     pointer: $pointer,
     release_deployed: $release_deployed,
     release_active: $release_active,
     build_v1: $build_v1,
     build_v2: $build_v2,
     smoke_url: $smoke_url,
     smoke_tool: $smoke_tool,
     smoke: [
       { stage: "5",  expect: $build_v1, reject: null },
       { stage: "5b", expect: $build_v2, reject: $build_v1 },
       { stage: "5c", expect: $build_v1, reject: $build_v2 }
     ],
     rollback: {
       from: $build_v2,
       to: $build_v1,
       from_release: $release_deployed,
       to_release: $release_active,
       ops: $rb_ops,
       ms: $rb_ms
     }
   }' > "${OUT}"

echo "==> metadata hasil run ditulis ke ${OUT}"
cat "${OUT}"
