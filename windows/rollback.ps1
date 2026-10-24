<#
.SYNOPSIS
  Kembalikan physicalPath site ke rilis sebelum ini.

.DESCRIPTION
  Rollback bukan jalur kode khusus, cuma deploy ke arah sebaliknya: pointer yang sama
  diarahkan ke folder rilis yang lama. Memakai mekanisme yang identik dengan deploy
  berarti rollback tidak bisa busuk tanpa deploy ikut busuk juga.

  Bandingkan dengan linux/rollback.sh. Di Linux rollback selesai setelah satu rename
  symlink. Di sini masih ada satu langkah lagi, recycle app pool, karena worker process
  dan cache http.sys bisa masih memegang isi rilis sebelumnya.

  Idempotent: previous.txt dihapus setelah dipakai, jadi menjalankan script ini dua
  kali berturut-turut bukan bolak-balik antar dua rilis, melainkan no-op yang eksplisit.

  Harus dijalankan dengan Windows PowerShell 5.1, bukan pwsh 7.
#>
[CmdletBinding()]
param(
    [string]$SiteName = 'demo',
    [string]$Root     = 'C:\inetpub\demo'
)

$ErrorActionPreference = 'Stop'
Import-Module WebAdministration

$previous = Join-Path $Root 'previous.txt'

# --- 1. Cek apakah ada tujuan rollback ------------------------------------------
$target = $null
if (Test-Path $previous) {
    $target = (Get-Content -Path $previous | Select-Object -First 1)
}

if ([string]::IsNullOrWhiteSpace($target)) {
    Write-Host '==> tidak ada rilis sebelumnya yang tercatat, tidak ada yang perlu dirollback'
    exit 0
}

# --- 2. Validasi tujuan masih ada di disk ---------------------------------------
# Rilis bisa sudah terpangkas, atau path-nya salah. Lebih baik gagal keras di sini
# daripada mengarahkan site ke folder yang tidak ada dan menghasilkan HTTP 500.
if (-not (Test-Path $target)) {
    throw "rilis tujuan rollback tidak ada di disk: $target"
}

$current = (Get-ItemProperty "IIS:\Sites\$SiteName" -Name physicalPath).Value
Write-Host "==> rollback dari $current"
Write-Host "               ke $target"

# --- 3. Swap pointer, cara yang sama persis dengan deploy -----------------------
Set-ItemProperty "IIS:\Sites\$SiteName" -Name physicalPath -Value $target

# --- 4. Recycle app pool --------------------------------------------------------
# Inilah langkah yang tidak punya padanan di sisi Linux. Mengganti pointer saja belum
# menjamin request berikutnya melihat isi yang baru.
Restart-WebAppPool -Name $SiteName

# --- 5. Habiskan catatan rollback -----------------------------------------------
# Dihapus, bukan ditukar, supaya rollback kedua jadi no-op dan bukan toggle.
Remove-Item -Path $previous -Force

Write-Host "==> physicalPath -> $target"
Write-Host '==> rollback selesai'
