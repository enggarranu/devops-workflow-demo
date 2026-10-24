# devops-workflow-demo

Satu pipeline CI yang mendeploy aplikasi web static yang sama ke dua environment:
nginx di Linux dan IIS di Windows Server. Tujuannya membandingkan langkah operasional
kedua platform secara berdampingan, dari run yang benar-benar berjalan.

Seluruh deployment terjadi di dalam GitHub runner. Tidak ada server, cloud account,
atau kredensial di luar CI, jadi repo ini bisa di-fork dan dijalankan siapa saja tanpa
menyiapkan apa pun.

> Catatan: repo ini dibuat sebagai bahan belajar dan demo. Script di sini ditulis untuk
> dijalankan di GitHub runner yang sekali pakai, bukan diambil apa adanya untuk
> production.

## Yang ditunjukkan

Tujuh stage yang sama, dua job paralel dari satu file workflow.

| Stage | Linux (`ubuntu-latest`) | Windows (`windows-latest`) |
| --- | --- | --- |
| 1. Trigger | `on: push` ke `main` | job kedua, event yang sama |
| 2. Package | `tar -czf` | `Compress-Archive` |
| 3. Siapkan web server | `apt-get install nginx` | nyalakan fitur IIS lewat DISM |
| 4. Deploy | rilis baru, swap symlink `current` | rilis baru, swap `physicalPath` site |
| 5. Smoke test | `curl -f` + assert build id | `Invoke-WebRequest` + assert build id |
| 6. Rollback | symlink balik ke rilis sebelumnya | `physicalPath` balik + recycle app pool |
| 7. Lock probe | `rm` file yang fd-nya dipegang | tulis ke handle `FileShare.None` |

Dua rilis dideploy dalam satu run, lalu dirollback. Jadi setiap run membuktikan rollback
bekerja, bukan cuma membuktikan file rollback-nya ada.

## Kenapa deploy-nya mengganti pointer, bukan menimpa folder

Keduanya memakai pola yang sama: tiap rilis masuk ke folder sendiri yang tidak pernah
disentuh lagi, lalu satu pointer diarahkan ke folder itu.

```
<root>/
  releases/0001/  0002/  0003/      rilis, nomor increment, 5 terakhir disimpan
  current -> releases/0003          Linux: symlink
                                    Windows: nilai physicalPath site
  previous                          path rilis sebelumnya, ditulis saat swap
```

Yang berbeda hanya bentuk pointer-nya. Di Linux, symlink di filesystem, diganti dengan
satu `rename` yang atomic. Di IIS, atribut `physicalPath` site di
`applicationHost.config`, yang dipantau IIS dan dimuat ulang tanpa restart.

Konsekuensinya: tidak pernah ada file yang sedang dilayani yang perlu ditimpa, jadi
seluruh persoalan file lock Windows tidak muncul di jalur deploy. Rollback jadi satu
operasi yang sama, cuma ke arah sebaliknya.

`app_offline.htm` sengaja tidak dipakai. File itu hanya dihormati handler ASP.NET dan
ASP.NET Core Module, bukan static file handler IIS, jadi untuk site static HTML seperti
ini tidak akan pernah tampil.

## Soal klaim "Windows mengunci file yang sedang dipakai"

Klaim itu benar, tapi tidak di semua lapisan, dan stage 7 memisahkan keduanya daripada
menggabungkannya jadi satu cerita yang terdengar rapi:

- **Di level sistem operasi, bedanya nyata dan deterministik.** Handle Windows yang
  dibuka dengan `FileShare.None` memblokir penulisan maupun penghapusan selama handle
  itu terbuka. Di Linux, `rm` pada file yang file descriptor-nya masih dipegang proses
  lain selalu berhasil, dan pemegang fd tetap membaca isi lama. Ini **diassert** di CI:
  kalau tidak sesuai, job-nya merah.
- **Lewat IIS untuk konten static, lock itu biasanya tidak terlihat.** IIS tidak memegang
  handle eksklusif atas file static, jadi menimpa `index.html` yang sedang dilayani
  umumnya berhasil. Yang muncul masalah lain: response bisa masih berisi isi lama karena
  cache http.sys. Ini **dilaporkan apa adanya**, tidak diassert, karena hasilnya
  tergantung image runner.

Hasil kedua eksperimen ditulis ke step summary tiap job, jadi bisa dibandingkan
berdampingan di halaman run.

## Cara reproduce dari nol

1. Fork repo ini, atau clone lalu push ke repo baru milik sendiri.
2. Pastikan GitHub Actions aktif di tab **Settings → Actions**.
3. Push apa pun ke branch `main`, atau jalankan manual dari tab **Actions** →
   **deploy** → **Run workflow**.
4. Buka run-nya. Dua job jalan paralel: `nginx di ubuntu-latest` dan
   `IIS di windows-latest`.
5. Baca **Summary** di halaman run. Di situ ada rilis mana yang aktif setelah rollback,
   dan tabel hasil lock probe dari kedua OS.

Tidak ada secret, variable, atau self-hosted runner yang perlu disiapkan.

### Berapa lama

| Job | Perkiraan |
| --- | --- |
| Linux | ~1 menit |
| Windows | ~4–6 menit |

Job Windows jauh lebih lambat karena IIS tidak terpasang di image `windows-latest` dan
harus dinyalakan dulu sebagai Windows optional feature. Langkah itu sendiri memakan satu
sampai tiga menit, dan itulah langkah terlambat di seluruh pipeline.

Runner Windows ditagih 2× menit di repo privat. Repo ini publik, jadi gratis.

## Menjalankan script Linux di luar CI

Script Linux tidak mengandung path yang hanya berlaku di runner. Root-nya bisa dipindah
lewat `DEMO_ROOT`, jadi logika rilis dan rollback bisa dicoba tanpa nginx dan tanpa sudo:

```bash
tar -czf app.tar.gz -C app .

export DEMO_ROOT=/tmp/demo-root
./linux/deploy.sh   coba-v1 app.tar.gz
./linux/deploy.sh   coba-v2 app.tar.gz
readlink -f "$DEMO_ROOT/current"        # -> releases/0002

./linux/rollback.sh
readlink -f "$DEMO_ROOT/current"        # -> releases/0001

./linux/rollback.sh                     # no-op, bukan toggle balik ke 0002
```

Butuh GNU coreutils, jadi jalankan di Linux. Di macOS, `readlink -f`, `mv -T`, dan
`sed -i` tanpa argumen berperilaku berbeda atau tidak ada.

Script Windows butuh IIS dan Windows PowerShell 5.1, jadi hanya bisa dijalankan di
Windows. Semuanya idempotent dan aman dijalankan dua kali berturut-turut.

## Isi repo

```
.github/workflows/deploy.yml   dua job paralel, tujuh stage
app/index.html                 aplikasi yang dideploy, berisi token __BUILD_ID__

linux/nginx-demo.conf          server block port 8080, root menunjuk symlink
linux/deploy.sh                rilis baru, swap symlink
linux/rollback.sh              symlink balik ke rilis yang dicatat
linux/smoke-test.sh            curl + assert isi, dengan retry
linux/lock-probe.sh            eksperimen unlink semantics

windows/iis-setup.ps1          nyalakan fitur IIS, buat app pool dan site
windows/deploy.ps1             rilis baru, swap physicalPath
windows/rollback.ps1           physicalPath balik, recycle app pool
windows/smoke-test.ps1         Invoke-WebRequest + assert isi, dengan retry
windows/lock-probe.ps1         eksperimen FileShare.None
```

Semua step Windows memakai `shell: powershell`, yaitu Windows PowerShell 5.1, bukan
`pwsh` 7. Di PowerShell 7, modul DISM dan `WebAdministration` hanya bisa diakses lewat
lapisan kompatibilitas Windows PowerShell, dan drive penyedia `IIS:\` tidak tersedia
di sana.
