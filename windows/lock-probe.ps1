<#
.SYNOPSIS
  Uji semantik file locking Windows, untuk dibandingkan langsung dengan
  linux/lock-probe.sh.

.DESCRIPTION
  Dijalankan sebagai stage terakhir, karena eksperimen A sengaja menimpa index.html
  rilis yang sedang aktif. Tidak ada stage lain sesudahnya yang bergantung pada isi itu.

  Dua eksperimen, dan pemisahannya penting:

    A. Menimpa file yang sedang dilayani IIS. Hasilnya DILAPORKAN apa adanya, tidak
       diassert. Untuk konten static, IIS umumnya tidak memegang handle eksklusif, jadi
       penulisannya sering berhasil. Yang biasanya muncul bukan error lock melainkan
       masalah lain: response masih isi lama karena cache http.sys.

    B. Menghapus dan menimpa file yang handle-nya dipegang proses lain dengan
       FileShare.None. Ini perbedaan sistem operasi yang deterministik, jadi di sini
       boleh gagal keras.

  Kenapa dipisah: klaim "Windows mengunci file yang sedang dipakai" benar di level
  semantik OS, yaitu eksperimen B, tapi untuk static HTML lewat IIS tidak selalu
  terlihat, yaitu eksperimen A. Membedakan keduanya lebih berguna daripada mengklaim
  lock yang tidak bisa ditunjukkan di layar.

  Harus dijalankan dengan Windows PowerShell 5.1, bukan pwsh 7.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][int]$Port,
    [string]$SiteName = 'demo',
    [string]$Root     = 'C:\inetpub\demo'
)

$ErrorActionPreference = 'Stop'
Import-Module WebAdministration

$url  = "http://localhost:$Port/"
$rows = @()   # dikumpulkan sebagai baris tabel markdown, ditulis sekali di akhir

Write-Host '=============================================='
Write-Host ' lock probe: Windows'
Write-Host '=============================================='

# ---------------------------------------------------------------------------------
# Eksperimen A: timpa file yang sedang dilayani IIS
# ---------------------------------------------------------------------------------
# Write-Host ''
# Write-Host '--- A: timpa index.html yang sedang dilayani IIS ---'

# $activePath = (Get-ItemProperty "IIS:\Sites\$SiteName" -Name physicalPath).Value
# $target     = Join-Path $activePath 'index.html'

# --- A: timpa index.html yang sedang dilayani IIS ---
Write-Host ''
Write-Host '--- A: timpa index.html yang sedang dilayani IIS ---'

$activePath = (Get-ItemProperty "IIS:\Sites\$SiteName" -Name physicalPath -ErrorAction SilentlyContinue).Value

# Fallback: jika physicalPath IIS kosong atau tidak valid, ambil rilis terakhir di disk
if (-not $activePath -or -not (Test-Path $activePath)) {
    $releasesDir = Join-Path $Root 'releases'
    $latestRelease = Get-ChildItem -Path $releasesDir -Directory -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -match '^\d+$' } |
                     Sort-Object { [int]$_.Name } |
                     Select-Object -Last 1
    
    if ($latestRelease) {
        $activePath = $latestRelease.FullName
    } else {
        $activePath = $Root
    }
}

$target = Join-Path $activePath 'index.html'

# Minta satu request dulu, supaya file benar-benar sudah pernah dibuka IIS dan bukan
# file yang belum tersentuh. Tanpa langkah ini eksperimennya tidak menguji apa pun.
$before = (Invoke-WebRequest -Uri $url -UseBasicParsing).Content
Write-Host "sebelum: $($before.Length) byte"

$marker    = "lock-probe-$PID"
$writeOk   = $false
$writeNote = ''
try {
    [System.IO.File]::WriteAllText($target, "<!doctype html><p>$marker</p>")
    $writeOk = $true
    Write-Host 'tulis: BERHASIL'
} catch {
    # Satu catch generik, bukan catch [System.IO.IOException]. Eksperimen A memang
    # tidak boleh menggagalkan step: kalau penulisannya ditolak, itu justru lock yang
    # dicari dan tetap dilaporkan sebagai hasil. Sebab lain, misalnya
    # UnauthorizedAccessException karena izin, juga ikut tercatat apa adanya daripada
    # menjatuhkan seluruh job.
    $writeNote = $_.Exception.GetType().Name
    Write-Host "tulis: GAGAL ($writeNote)"
}

if ($writeOk) {
    # Dua percobaan dengan jeda, karena http.sys bisa melayani response dari cache
    # kernel beberapa saat walaupun file di disk sudah berganti. Ini perbedaan nyata
    # dengan nginx, yang membuka ulang file tiap request.
    $sawNew = $false
    foreach ($attempt in 1..3) {
        if ((Invoke-WebRequest -Uri $url -UseBasicParsing).Content -match [regex]::Escape($marker)) {
            $sawNew = $true
            Write-Host "request ke-$attempt : isi BARU"
            break
        }
        Write-Host "request ke-$attempt : masih isi LAMA"
        Start-Sleep -Seconds 2
    }
    $note = if ($sawNew) { 'isi baru terlihat' } else { 'response masih isi lama (cache http.sys)' }
    $rows += "| A. Timpa file yang sedang dilayani | berhasil | $note |"
} else {
    $rows += "| A. Timpa file yang sedang dilayani | gagal | $writeNote |"
}

# ---------------------------------------------------------------------------------
# Eksperimen B: file yang handle-nya dipegang proses lain
# ---------------------------------------------------------------------------------
Write-Host ''
Write-Host '--- B: timpa dan hapus file yang handle-nya dipegang (FileShare.None) ---'

$scratch = Join-Path $env:TEMP "lock-probe-$PID"
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$held = Join-Path $scratch 'held.txt'
[System.IO.File]::WriteAllText($held, 'isi-asli')

# FileShare.None berarti: selama handle ini terbuka, tidak ada proses lain yang boleh
# membuka file ini untuk apa pun. Inilah mode yang dipakai banyak runtime saat memuat
# assembly, dan alasan deploy di Windows butuh maintenance window.
$stream = [System.IO.File]::Open(
    $held,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::None)

try {
    # B1: coba timpa. Harus ditolak.
    $overwriteBlocked = $false
    $overwriteNote    = ''
    try {
        [System.IO.File]::WriteAllText($held, 'isi-baru')
        Write-Host 'timpa: BERHASIL (tidak diharapkan di Windows)'
    } catch [System.IO.IOException] {
        $overwriteBlocked = $true
        $overwriteNote    = $_.Exception.GetType().Name
        Write-Host 'timpa: DITOLAK, file sedang dipakai proses lain'
    }

    # B2: coba hapus. Juga harus ditolak. Ini kontras paling tajam dengan Linux,
    # di mana rm pada file yang fd-nya masih dipegang selalu berhasil.
    $deleteBlocked = $false
    $deleteNote    = ''
    try {
        [System.IO.File]::Delete($held)
        Write-Host 'hapus: BERHASIL (tidak diharapkan di Windows)'
    } catch [System.IO.IOException] {
        $deleteBlocked = $true
        $deleteNote    = $_.Exception.GetType().Name
        Write-Host 'hapus: DITOLAK, file sedang dipakai proses lain'
    }

    # Premis seluruh demo bergantung pada dua hasil ini, jadi kalau tidak sesuai lebih
    # baik pipeline-nya merah daripada klaimnya dibawa ke interview tanpa bukti.
    #
    # Yang ditangkap hanya IOException, sengaja tidak catch generik. Exception lain
    # berarti eksperimennya sendiri yang rusak, bukan lock yang terbukti, dan itu
    # memang harus menjatuhkan job daripada dilaporkan sebagai lock palsu.
    if (-not $overwriteBlocked) { throw 'premis salah: penulisan ke file terkunci ternyata diizinkan' }
    if (-not $deleteBlocked)    { throw 'premis salah: penghapusan file terkunci ternyata diizinkan' }

    $rows += "| B. Timpa file yang handle-nya dipegang | ditolak | $overwriteNote |"
    $rows += "| B. Hapus file yang handle-nya dipegang | ditolak | $deleteNote |"
}
finally {
    # Handle harus ditutup walau ada yang gagal di atas, kalau tidak folder scratch
    # ikut terkunci dan step cleanup berikutnya yang gagal.
    $stream.Dispose()
    Remove-Item -Path $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------------
# Ringkasan
# ---------------------------------------------------------------------------------
if ($env:GITHUB_STEP_SUMMARY) {
    $summary = @()
    $summary += '### Lock probe: Windows'
    $summary += ''
    $summary += '| Eksperimen | Hasil | Catatan |'
    $summary += '| --- | --- | --- |'
    $summary += $rows
    $summary += ''
    $summary += 'Di Windows, berbagi akses ke file adalah sesuatu yang harus diminta eksplisit.'
    $summary += 'Begitu sebuah handle dibuka dengan FileShare.None, file itu tidak bisa ditimpa'
    $summary += 'maupun dihapus sampai handle-nya ditutup. Karena itu deploy di Windows secara'
    $summary += 'tradisional butuh maintenance window, dan karena itu pipeline ini memilih'
    $summary += 'mengganti pointer physicalPath, bukan menimpa folder yang sedang dilayani.'
    $summary -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

Write-Host ''
Write-Host '==> lock probe Windows selesai'
