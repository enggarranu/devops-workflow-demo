<#
.SYNOPSIS
  Nyalakan IIS di runner, lalu buat app pool dan site untuk aplikasi demo.

.DESCRIPTION
  IIS tidak terpasang di image windows-latest, jadi harus dinyalakan dulu sebagai
  Windows optional feature. Ini langkah paling lambat di seluruh pipeline, kira-kira
  satu sampai tiga menit.

  Script ini idempotent: fitur dicek sebelum dinyalakan dan site dicek sebelum dibuat,
  jadi aman dijalankan dua kali berturut-turut.

  CATATAN PENTING soal shell. Script ini harus dijalankan dengan Windows PowerShell 5.1
  (`shell: powershell` di workflow), bukan PowerShell 7 (`pwsh`). Di PowerShell 7, modul
  DISM dan WebAdministration cuma bisa diakses lewat lapisan kompatibilitas Windows
  PowerShell, dan drive penyedia `IIS:\` tidak tersedia di sana.
#>
[CmdletBinding()]
param(
    [string]$SiteName = 'demo',
    [int]   $Port     = 8080,
    [string]$Root     = 'C:\inetpub\demo'
)

$ErrorActionPreference = 'Stop'

Write-Host '==> menyiapkan IIS'

# --- 1. Nyalakan fitur IIS yang dibutuhkan ---------------------------------------
# IIS-ManagementScriptingTools paling mudah terlupa dan paling menyesatkan kalau
# tidak ada: IIS sendiri hidup dan melayani halaman, tapi Import-Module
# WebAdministration gagal dan semua cmdlet *-Website ikut gagal, jadi error-nya
# kelihatan seperti masalah modul, bukan masalah fitur yang belum dipasang.
$features = @(
    'IIS-WebServerRole'
    'IIS-WebServer'
    'IIS-CommonHttpFeatures'
    'IIS-StaticContent'
    'IIS-DefaultDocument'
    'IIS-HttpErrors'
    'IIS-ManagementScriptingTools'
)

$missing = @()
foreach ($feature in $features) {
    if ((Get-WindowsOptionalFeature -Online -FeatureName $feature).State -ne 'Enabled') {
        $missing += $feature
    }
}

if ($missing.Count -gt 0) {
    Write-Host "    menyalakan $($missing.Count) fitur: $($missing -join ', ')"
    # Semua fitur dalam satu panggilan, karena tiap panggilan DISM punya overhead
    # beberapa puluh detik sendiri.
    #
    # -NoRestart wajib: runner tidak bisa direboot di tengah job. Untuk daftar fitur
    # di atas, IIS tetap berfungsi tanpa reboot.
    #
    # Kalau cmdlet ini suatu saat gagal atau menggantung, alternatifnya DISM langsung:
    #   dism.exe /online /enable-feature /all /norestart /featurename:IIS-WebServerRole
    $result = Enable-WindowsOptionalFeature -Online -FeatureName $missing -All -NoRestart
    if ($result.RestartNeeded) {
        Write-Host '    DISM meminta reboot, diabaikan dengan sengaja (lihat komentar di atas)'
    }
} else {
    Write-Host '    semua fitur IIS sudah menyala, dilewati'
}

# --- 2. Pastikan servis IIS benar-benar jalan ------------------------------------
# Menyalakan fitur tidak selalu ikut menyalakan servisnya, dan karena reboot dilewati
# statusnya perlu dipaksa dan diverifikasi di sini, bukan diasumsikan.
foreach ($svc in @('WAS', 'W3SVC')) {
    $service = Get-Service -Name $svc
    if ($service.Status -ne 'Running') {
        Write-Host "    menyalakan servis $svc"
        Start-Service -Name $svc
    }
    (Get-Service -Name $svc).WaitForStatus('Running', '00:01:00')
}

Import-Module WebAdministration

# --- 3. Siapkan struktur direktori ----------------------------------------------
# bootstrap adalah physicalPath awal site, dipakai hanya sampai deploy pertama
# mengarahkan site ke folder rilis sebenarnya. Site IIS tidak bisa dibuat tanpa
# physicalPath yang valid, jadi harus ada sesuatu di sini.
$releases  = Join-Path $Root 'releases'
$bootstrap = Join-Path $Root 'bootstrap'
New-Item -ItemType Directory -Path $releases  -Force | Out-Null
New-Item -ItemType Directory -Path $bootstrap -Force | Out-Null

if (-not (Test-Path (Join-Path $bootstrap 'index.html'))) {
    Set-Content -Path (Join-Path $bootstrap 'index.html') `
                -Value '<!doctype html><p>belum ada rilis</p>' -Encoding UTF8
}

# --- 4. Beri izin baca ke identitas app pool ------------------------------------
# Ini penyebab HTTP 403 paling umum di IIS yang baru dipasang. Folder di bawah
# C:\inetpub biasanya sudah mewarisi izin untuk IIS_IUSRS, tapi tidak dijamin, jadi
# izinnya diberikan eksplisit. (RX) = read + execute, diwariskan ke isi folder.
Write-Host '    memberi izin baca ke IIS_IUSRS'
& icacls.exe $Root /grant 'IIS_IUSRS:(OI)(CI)(RX)' /T /C /Q | Out-Null

# --- 5. Buat app pool -----------------------------------------------------------
if (-not (Test-Path "IIS:\AppPools\$SiteName")) {
    Write-Host "    membuat app pool $SiteName"
    New-WebAppPool -Name $SiteName | Out-Null
}
# Site ini static HTML saja, tidak ada .NET yang perlu dimuat. Setara dengan memilih
# "No Managed Code" di IIS Manager: satu CLR lebih sedikit yang di-load per worker.
Set-ItemProperty "IIS:\AppPools\$SiteName" -Name managedRuntimeVersion -Value ''

# --- 6. Buat site ---------------------------------------------------------------
# Get-Website -Name dipakai lewat Where-Object, karena Get-Website dengan -Name yang
# tidak cocok berperilaku tidak konsisten antar versi: ada yang error, ada yang
# malah mengembalikan seluruh site.
$site = Get-Website | Where-Object { $_.Name -eq $SiteName }

if (-not $site) {
    # Port 8080, bukan 80. Default Web Site sudah memegang port 80 dan sengaja tidak
    # disentuh sama sekali, jadi tidak ada binding yang bisa bentrok.
    # Angka ini harus sama dengan env APP_PORT di .github/workflows/deploy.yml.
    Write-Host "    membuat site $SiteName di port $Port"
    New-Website -Name $SiteName -Port $Port -PhysicalPath $bootstrap `
                -ApplicationPool $SiteName | Out-Null
} else {
    Write-Host "    site $SiteName sudah ada, dilewati"
}

if ((Get-Website | Where-Object { $_.Name -eq $SiteName }).State -ne 'Started') {
    Start-Website -Name $SiteName
}

# --- 7. Verifikasi, jangan diasumsikan ------------------------------------------
# Kalau salah satu dari tiga hal ini tidak benar, lebih baik gagal di sini daripada
# gagal nanti di smoke test dengan pesan yang tidak menunjuk ke penyebabnya.
$site = Get-Website | Where-Object { $_.Name -eq $SiteName }
if (-not $site)                   { throw "site $SiteName tidak terbentuk" }
if ($site.State -ne 'Started')    { throw "site $SiteName tidak jalan: $($site.State)" }

$pool = Get-Item "IIS:\AppPools\$SiteName"
if ($pool.State -ne 'Started')    { throw "app pool $SiteName tidak jalan: $($pool.State)" }

$binding = $site.Bindings.Collection | Where-Object { $_.bindingInformation -like "*:$Port`:*" }
if (-not $binding)                { throw "site $SiteName tidak punya binding di port $Port" }

Write-Host "==> IIS siap: site '$SiteName' jalan di port $Port"
Write-Host "    physicalPath saat ini: $((Get-ItemProperty "IIS:\Sites\$SiteName" -Name physicalPath).Value)"
