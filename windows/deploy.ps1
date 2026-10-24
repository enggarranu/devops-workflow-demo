<#
.SYNOPSIS
  Deploy satu rilis baru ke IIS, lalu arahkan physicalPath site ke rilis itu.

.DESCRIPTION
  Strategi: rilis immutable + swap pointer, sama persis dengan linux/deploy.sh. Yang
  berbeda hanya pointer-nya. Di Linux pointer itu symlink `current` di filesystem; di
  IIS pointer itu atribut physicalPath site di applicationHost.config.

  Keuntungannya sama di kedua platform: folder rilis yang sudah jadi tidak pernah
  disentuh lagi, jadi tidak ada file yang sedang dilayani yang perlu ditimpa, dan
  seluruh persoalan file lock Windows tidak pernah muncul.

  Yang TIDAK dipakai di sini: app_offline.htm. File itu hanya dihormati oleh handler
  ASP.NET / ASP.NET Core Module, bukan oleh static file handler IIS. Untuk site static
  HTML seperti ini, app_offline.htm tidak akan pernah tampil.

  Harus dijalankan dengan Windows PowerShell 5.1, bukan pwsh 7. Alasannya ada di
  windows/iis-setup.ps1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BuildId,
    [Parameter(Mandatory = $true)][string]$PackagePath,
    [string]$SiteName = 'demo',
    [string]$Root     = 'C:\inetpub\demo'
)

$ErrorActionPreference = 'Stop'
Import-Module WebAdministration

$releases = Join-Path $Root 'releases'
$previous = Join-Path $Root 'previous.txt'
$keep     = 5   # jumlah rilis yang disimpan, sisanya dipangkas

if (-not (Test-Path $PackagePath)) { throw "paket tidak ada: $PackagePath" }

# --- 1. Siapkan struktur direktori ----------------------------------------------
New-Item -ItemType Directory -Path $releases -Force | Out-Null

# --- 2. Tentukan nomor rilis berikutnya -----------------------------------------
# Nomor berurut dan zero-padded, supaya urutannya terbaca sama seperti di sisi Linux.
# Pengurutan pakai [int], bukan string, supaya 0010 tidak dianggap sebelum 0009.
$last = Get-ChildItem -Path $releases -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+$' } |
        Sort-Object { [int]$_.Name } |
        Select-Object -Last 1

$next       = '{0:d4}' -f ([int]($last.Name) + 1)
$releaseDir = Join-Path $releases $next

Write-Host "==> rilis $next  (build $BuildId)"

# --- 3. Bongkar paket ke folder rilis baru --------------------------------------
New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null
Expand-Archive -Path $PackagePath -DestinationPath $releaseDir -Force

# --- 4. Cap build id ke dalam artefak -------------------------------------------
# Ini yang membuat tiap rilis bisa dibedakan dari luar lewat HTTP, sehingga smoke test
# setelah rollback bisa membuktikan isi yang dilayani benar-benar berubah.
#
# Dipakai .Replace() milik String, bukan operator -replace, karena -replace
# memperlakukan pola sebagai regex dan tanda $ di string pengganti sebagai acuan
# grup tangkapan. Untuk substitusi literal seperti ini, .Replace() tidak punya
# kejutan semacam itu.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
foreach ($file in Get-ChildItem -Path $releaseDir -Recurse -File -Filter '*.html') {
    $content = [System.IO.File]::ReadAllText($file.FullName)
    [System.IO.File]::WriteAllText($file.FullName, $content.Replace('__BUILD_ID__', $BuildId), $utf8NoBom)
}

$indexPath = Join-Path $releaseDir 'index.html'
if (-not (Select-String -Path $indexPath -Pattern $BuildId -SimpleMatch -Quiet)) {
    throw 'build id gagal dicap ke index.html'
}

# --- 5. Beri izin baca ke identitas app pool ------------------------------------
# Folder rilis baru belum tentu mewarisi izin yang benar, dan app pool yang tidak bisa
# membaca folder-nya menghasilkan HTTP 403, bukan error saat deploy. Jadi izinnya
# diberikan di sini, sebelum site diarahkan ke folder ini.
& icacls.exe $releaseDir /grant 'IIS_IUSRS:(OI)(CI)(RX)' /T /C /Q | Out-Null

# --- 6. Catat rilis yang sedang aktif sebagai tujuan rollback -------------------
# Dicatat SEBELUM swap, selagi physicalPath masih menunjuk rilis lama.
$activePath = (Get-ItemProperty "IIS:\Sites\$SiteName" -Name physicalPath).Value

if ($activePath -and $activePath.StartsWith($releases, [System.StringComparison]::OrdinalIgnoreCase)) {
    Set-Content -Path $previous -Value $activePath -Encoding ASCII
    Write-Host "    rollback target dicatat: $activePath"
} else {
    # Deploy pertama: physicalPath masih menunjuk folder bootstrap, yang bukan rilis dan
    # tidak melayani apa-apa. Mencatatnya sebagai tujuan rollback akan menghasilkan
    # rollback yang "berhasil" tapi menyajikan halaman kosong, jadi dikosongkan saja.
    Set-Content -Path $previous -Value '' -Encoding ASCII
    Write-Host '    deploy pertama, belum ada rollback target'
}

# --- 7. Swap pointer ------------------------------------------------------------
# Satu perubahan atribut di applicationHost.config. IIS memantau file itu dan memuat
# ulang konfigurasi site tanpa perlu restart, jadi inilah padanan terdekat dari
# `mv -T` pada symlink di sisi Linux.
Set-ItemProperty "IIS:\Sites\$SiteName" -Name physicalPath -Value $releaseDir

# --- 8. Recycle app pool --------------------------------------------------------
# Langkah ini tidak ada padanannya di sisi Linux, dan itu justru salah satu perbedaan
# yang jadi inti demo. Tanpa recycle, worker process dan cache http.sys bisa masih
# melayani isi rilis sebelumnya untuk beberapa saat setelah pointer berganti.
#
# Sengaja TIDAK memakai iisreset: itu mematikan seluruh servis IIS, lambat, dan ikut
# menjatuhkan site lain di mesin yang sama.
Restart-WebAppPool -Name $SiteName

Write-Host "==> physicalPath -> $releaseDir"

# --- 9. Pangkas rilis lama ------------------------------------------------------
# Rilis yang masih jadi tujuan rollback dilindungi eksplisit, supaya tidak terhapus.
$protected = @($releaseDir)
$recorded  = (Get-Content -Path $previous -ErrorAction SilentlyContinue | Select-Object -First 1)
if ($recorded) { $protected += $recorded }

$all = Get-ChildItem -Path $releases -Directory |
       Where-Object { $_.Name -match '^\d+$' } |
       Sort-Object { [int]$_.Name }

if ($all.Count -gt $keep) {
    foreach ($old in $all[0..($all.Count - $keep - 1)]) {
        if ($protected -contains $old.FullName) { continue }
        Write-Host "    pangkas rilis lama: $($old.Name)"
        Remove-Item -Path $old.FullName -Recurse -Force
    }
}

Write-Host '==> deploy selesai'
