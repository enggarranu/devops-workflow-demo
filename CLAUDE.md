# devops-workflow-demo

Demo yang membandingkan workflow deployment aplikasi web di dua environment, Linux
dengan nginx dan Windows Server dengan IIS, lewat satu pipeline CI yang sama. Hasil
akhirnya dua bagian: pipeline yang benar-benar berjalan, dan website penjelas yang
di-host di GitHub Pages.

## Struktur

```
.github/workflows/deploy.yml   tiga job: linux, windows, publish
app/index.html                 aplikasi yang dideploy, static HTML
linux/                         nginx-demo.conf, deploy.sh, rollback.sh,
                               smoke-test.sh, lock-probe.sh, write-result.sh
windows/                       iis-setup.ps1, iis-path.ps1, deploy.ps1,
                               rollback.ps1, smoke-test.ps1, lock-probe.ps1,
                               write-result.ps1
publish/                       template.html, render.py, push-result.sh
docs/index.html                website, dilayani GitHub Pages dari folder docs/
docs/result/                   halaman hasil per jalur, DIBUAT OTOMATIS
README.md                      cara reproduce dari nol
```

## Constraint

- Aplikasi demo cukup static HTML. Fokus proyek ada di pipeline-nya, bukan di aplikasinya.
- `docs/index.html` harus satu file self-contained: CSS dan JS inline, tanpa CDN, tanpa
  font eksternal. Website ini dipresentasikan dari laptop dan harus tetap tampil utuh
  tanpa koneksi internet.
- Diagram dan animasi pakai SVG dan CSS saja, tanpa library animasi.
- Tidak ada server di luar GitHub runner. Semua deployment terjadi di dalam job CI.
- `docs/result/` dibuat otomatis oleh job `publish`. Jangan diedit langsung: perubahan
  di sana akan tertimpa pada run berikutnya. Yang diedit `publish/template.html` dan
  `publish/render.py`.
- Halaman di `docs/result/` dilayani GitHub Pages, bukan nginx dan bukan IIS. Jangan
  menulis satu kata pun di situ yang menyiratkan sebaliknya: response header-nya dari
  GitHub, jadi klaim seperti itu langsung ketahuan. Yang benar: artifact-nya dibangun,
  dideploy, dan diverifikasi di runner pada run tertentu, lalu hasilnya dipublish ke
  sana sebagai bukti, dan runner-nya sudah dihancurkan setelah job selesai.

## Alur pipeline

Tujuh stage yang sama di kedua environment, dijalankan sebagai dua job dari satu
workflow. Bukan matrix: hampir setiap step berbeda isinya antar OS, jadi matrix hanya
akan menyembunyikan perbedaan yang justru mau ditunjukkan.

| Stage | Linux (`ubuntu-latest`) | Windows (`windows-latest`) |
| --- | --- | --- |
| 1. Trigger | `on: push` ke `main` | sama, satu workflow, dua job |
| 2. Package | `tar -czf` | `Compress-Archive` |
| 3. Siapkan web server | pasang nginx | aktifkan IIS |
| 4. Deploy | release baru, symlink `current` | release baru, swap `physicalPath` |
| 5. Smoke test | `curl -f` | `Invoke-WebRequest -UseBasicParsing` |
| 6. Rollback | symlink balik ke release sebelumnya | `physicalPath` balik, recycle app pool |
| 7. Lock probe | `rm` file yang fd-nya dipegang | tulis ke handle `FileShare.None` |

Setelah kedua job selesai, job `publish` mengunduh metadata JSON dari keduanya, merakit
`docs/result/linux/index.html` dan `docs/result/windows/index.html`, lalu commit dan
push. Dua job deploy sengaja tidak menulis ke repo: keduanya paralel, dan dua push ke
branch yang sama akan bentrok. Commit-nya diakhiri `[skip ci]` supaya tidak memicu
workflow ini lagi dan jadi loop.

Build id dan versi diambil dari `github.run_number`, bukan dari counter manual atau file
state di repo: `run_number` naik sendiri dan tidak pernah turun.

Perbedaan yang jadi inti demo: file yang sedang dipakai bisa ditimpa di Linux tapi
terkunci di Windows, sehingga rollback di Windows butuh langkah lebih panjang.

Klaim itu dipecah jadi dua di stage 7, karena hanya satu bagiannya yang deterministik:

- Di level sistem operasi, bedanya nyata dan selalu terjadi. Handle Windows yang dibuka
  dengan `FileShare.None` memblokir penulisan dan penghapusan; `rm` di Linux pada file
  yang file descriptor-nya masih dipegang selalu berhasil. Ini diassert di CI.
- Lewat IIS untuk konten static, lock itu biasanya TIDAK terlihat: IIS tidak memegang
  handle eksklusif, jadi menimpa file yang sedang dilayani umumnya berhasil. Apakah
  response berikutnya langsung berubah, itu dilaporkan apa adanya tanpa ditebak
  sebabnya, dan tidak diassert. Jangan menulis sebab (misalnya cache http.sys) di
  website sebelum ada bukti di log yang menunjuk ke sebab itu.

`app_offline.htm` sengaja tidak dipakai. File itu hanya dihormati handler ASP.NET dan
ASP.NET Core Module, bukan static file handler IIS, jadi untuk site static HTML seperti
ini tidak akan pernah tampil. Padanan terdekat dari symlink `current` di IIS adalah
atribut `physicalPath` site, dan itulah yang dipakai di kedua arah, deploy dan rollback.

## Konvensi

- Setiap stage punya smoke test yang gagal keras kalau deployment tidak benar.
- Setiap environment punya script rollback, dan rollback ikut dijalankan di CI supaya
  terbukti bekerja, bukan sekadar ada.
- Script ditulis idempotent, aman dijalankan dua kali berturut-turut.
- Bash pakai `set -euo pipefail`. PowerShell pakai `$ErrorActionPreference = 'Stop'`.
- Beri komentar singkat di tiap langkah penting. File di repo ini dibaca orang lain,
  jadi kejelasan lebih penting daripada keringkasan.

## Cara kerja yang diharapkan

- Tulis file utuh, bukan potongan yang harus disambung manual.
- Isi langkah di website diambil dari file script yang sebenarnya. Kalau script berubah,
  website ikut diperbarui supaya tidak ada dua versi yang berbeda.
- Kalau ada langkah yang berisiko gagal atau lambat di runner, sebutkan dan tawarkan
  alternatifnya, jangan diam-diam dipilihkan.
