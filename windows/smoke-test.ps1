<#
.SYNOPSIS
  Smoke test satu rilis yang sedang dilayani IIS.

.DESCRIPTION
  Padanan dari linux/smoke-test.sh, dengan logika yang sama persis supaya keduanya bisa
  dibandingkan baris per baris saat demo.

  -MustNotContain itulah yang membuat test ini bermakna setelah rollback. Mengecek
  "build lama muncul" saja belum cukup; mengecek sekaligus bahwa build baru sudah TIDAK
  muncul membuktikan pointer benar-benar berpindah.

  Harus dijalankan dengan Windows PowerShell 5.1, bukan pwsh 7.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$MustContain,
    [string]$MustNotContain = '',
    [int]   $Attempts       = 5,
    [int]   $DelaySeconds   = 2
)

$ErrorActionPreference = 'Stop'

Write-Host "==> smoke test $Url"
Write-Host "    harus ada        : $MustContain"
if ($MustNotContain) { Write-Host "    tidak boleh ada  : $MustNotContain" }

# Retry di sisi Windows lebih penting daripada di Linux. Setelah physicalPath berganti
# dan app pool di-recycle, http.sys bisa masih melayani response dari cache kernel dan
# worker process yang baru belum tentu sudah siap. Tanpa retry, test ini akan flaky
# karena balapan waktu, bukan karena deploy-nya salah.
$body    = ''
$matched = $false

foreach ($attempt in 1..$Attempts) {
    try {
        # -UseBasicParsing supaya tidak bergantung pada mesin DOM Internet Explorer,
        # yang tidak ada di image runner. Tanpa ini cmdlet-nya gagal, bukan lambat.
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 10
        $body     = $response.Content

        # SimpleMatch lewat .Contains(), bukan -match, supaya build id diperlakukan
        # sebagai teks biasa dan bukan pola regex.
        if ($body.Contains($MustContain)) {
            Write-Host "    percobaan $attempt : cocok"
            $matched = $true
            break
        }
        Write-Host "    percobaan $attempt : belum cocok"
    } catch {
        # Status 4xx/5xx dan koneksi gagal sama-sama berakhir di sini. Dicatat lalu
        # dicoba lagi, karena dua-duanya bisa sementara sesaat setelah recycle.
        Write-Host "    percobaan $attempt : $($_.Exception.Message)"
    }

    if ($attempt -lt $Attempts) { Start-Sleep -Seconds $DelaySeconds }
}

if (-not $matched) {
    Write-Host '--- response terakhir ---'
    Write-Host $(if ($body) { $body } else { '(kosong)' })
    throw "GAGAL: setelah $Attempts percobaan, `"$MustContain`" tidak ada di response"
}

# Pengecekan negatif tidak di-retry. Kalau string yang seharusnya hilang masih ada,
# menunggu tidak akan mengubah apa pun, dan rollback-nya memang gagal.
if ($MustNotContain -and $body.Contains($MustNotContain)) {
    Write-Host '--- response ---'
    Write-Host $body
    throw "GAGAL: `"$MustNotContain`" seharusnya sudah tidak dilayani, tapi masih ada"
}

Write-Host '==> smoke test lolos'
