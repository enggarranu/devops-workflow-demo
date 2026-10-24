# devops-workflow-demo

Demo yang membandingkan workflow deployment aplikasi web di dua environment, Linux
dengan nginx dan Windows Server dengan IIS, lewat satu pipeline CI yang sama. Hasil
akhirnya dua bagian: pipeline yang benar-benar berjalan, dan website penjelas yang
di-host di GitHub Pages.

## Struktur

```
.github/workflows/deploy.yml   dua job paralel, ubuntu-latest + windows-latest
app/index.html                 aplikasi yang dideploy, static HTML
linux/                         nginx-demo.conf, deploy.sh, rollback.sh,
                               smoke-test.sh, lock-probe.sh
windows/                       iis-setup.ps1, deploy.ps1, rollback.ps1,
                               smoke-test.ps1, lock-probe.ps1
docs/index.html                website, dilayani GitHub Pages dari folder docs/
README.md                      cara reproduce dari nol
```

## Constraint

- Aplikasi demo cukup static HTML. Fokus proyek ada di pipeline-nya, bukan di aplikasinya.
- `docs/index.html` harus satu file self-contained: CSS dan JS inline, tanpa CDN, tanpa
  font eksternal. Website ini dipresentasikan dari laptop dan harus tetap tampil utuh
  tanpa koneksi internet.
- Diagram dan animasi pakai SVG dan CSS saja, tanpa library animasi.
- Tidak ada server di luar GitHub runner. Semua deployment terjadi di dalam job CI.

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

Perbedaan yang jadi inti demo: file yang sedang dipakai bisa ditimpa di Linux tapi
terkunci di Windows, sehingga rollback di Windows butuh langkah lebih panjang.

Klaim itu dipecah jadi dua di stage 7, karena hanya satu bagiannya yang deterministik:

- Di level sistem operasi, bedanya nyata dan selalu terjadi. Handle Windows yang dibuka
  dengan `FileShare.None` memblokir penulisan dan penghapusan; `rm` di Linux pada file
  yang file descriptor-nya masih dipegang selalu berhasil. Ini diassert di CI.
- Lewat IIS untuk konten static, lock itu biasanya TIDAK terlihat: IIS tidak memegang
  handle eksklusif, jadi menimpa file yang sedang dilayani umumnya berhasil. Yang muncul
  masalah lain, yaitu response masih isi lama karena cache http.sys. Ini dilaporkan apa
  adanya, tidak diassert.

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
