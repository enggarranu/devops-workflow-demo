<#
.SYNOPSIS
  Catat hasil run ini sebagai satu file JSON, untuk dipublish job `publish`
  jadi halaman di GitHub Pages.

.DESCRIPTION
  Padanan dari linux/write-result.sh. Script ini tidak mengubah apa pun: dia
  hanya membaca keadaan nyata di runner setelah deploy, smoke test, dan rollback
  selesai, lalu menuliskannya.

  Rilis yang sedang dilayani dibaca lewat Get-SitePhysicalPath, bukan ditebak
  dari nomor rilis tertinggi. Itu pembedaan yang penting: setelah rollback,
  nomor tertinggi BUKAN yang sedang dilayani, dan menebaknya adalah bug yang
  pernah benar-benar terjadi di repo ini (lihat windows/iis-path.ps1).

  JSON dirakit lewat ConvertTo-Json dari hashtable, bukan string interpolation,
  supaya tidak ada nilai yang bisa merusak strukturnya. Ditulis tanpa BOM,
  karena parser JSON di job publish menolak BOM.

  Harus dijalankan dengan Windows PowerShell 5.1, bukan pwsh 7.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$SiteName = 'demo',
    [string]$Root     = 'C:\inetpub\demo'
)

$ErrorActionPreference = 'Stop'
Import-Module WebAdministration
. (Join-Path $PSScriptRoot 'iis-path.ps1')   # Get-SitePhysicalPath

$releases = Join-Path $Root 'releases'

# --- 1. Keadaan nyata di IIS dan di disk ----------------------------------------
# Rilis yang SEDANG dilayani, dibaca dari pointer-nya sendiri.
$releaseActive = Get-SitePhysicalPath -SiteName $SiteName

# Rilis dengan nomor tertinggi adalah yang dibuat deploy terakhir di run ini.
$latest = Get-ChildItem -Path $releases -Directory |
          Where-Object { $_.Name -match '^\d+$' } |
          Sort-Object { [int]$_.Name } |
          Select-Object -Last 1
$releaseDeployed = $latest.FullName

# --- 2. Versi web server dan OS -------------------------------------------------
# VersionString di InetStp berbunyi seperti "IIS 10.0". Dibungkus try/catch
# karena ini cuma hiasan di halaman hasil, bukan alasan memerahkan job.
$webServer = try {
    (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\InetStp' -Name VersionString).VersionString
} catch { 'IIS' }

$runnerOs = try {
    (Get-CimInstance Win32_OperatingSystem).Caption.Trim()
} catch { $env:ImageOS }

$commitSubject = (& git log -1 --pretty=%s) | Out-String

# --- 3. Rakit JSON --------------------------------------------------------------
# Urutan field-nya dibuat sama dengan versi Linux, supaya dua file ini bisa
# dibandingkan berdampingan saat dibaca orang.
$result = [ordered]@{
    platform          = 'windows'
    platform_label    = 'Windows'
    server_label      = 'IIS'
    runner_image      = 'windows-latest'
    runner_os         = $runnerOs
    web_server        = $webServer
    build_id          = $env:BUILD_ID
    version           = $env:VERSION
    run_id            = $env:GITHUB_RUN_ID
    run_number        = $env:GITHUB_RUN_NUMBER
    run_attempt       = $env:GITHUB_RUN_ATTEMPT
    run_url           = "$($env:GITHUB_SERVER_URL)/$($env:GITHUB_REPOSITORY)/actions/runs/$($env:GITHUB_RUN_ID)"
    repo              = $env:GITHUB_REPOSITORY
    commit_sha        = $env:GITHUB_SHA
    commit_url        = "$($env:GITHUB_SERVER_URL)/$($env:GITHUB_REPOSITORY)/commit/$($env:GITHUB_SHA)"
    commit_subject    = $commitSubject.Trim()
    deployed_at_utc   = $env:DEPLOY_AT
    deploy_method     = 'physicalPath swap'
    deploy_method_cmd = "Set-ItemProperty ""IIS:\Sites\$SiteName"" -Name physicalPath -Value <rilis>"
    pointer           = "applicationHost.config -> sites/site[@name='$SiteName'] @physicalPath"
    release_deployed  = $releaseDeployed
    release_active    = $releaseActive
    build_v1          = $env:BUILD_V1
    build_v2          = $env:BUILD_V2
    smoke_url         = "http://localhost:$($env:APP_PORT)/"
    smoke_tool        = 'Invoke-WebRequest -UseBasicParsing + .Contains()'
    smoke             = @(
        [ordered]@{ stage = '5';  expect = $env:BUILD_V1; reject = $null }
        [ordered]@{ stage = '5b'; expect = $env:BUILD_V2; reject = $env:BUILD_V1 }
        [ordered]@{ stage = '5c'; expect = $env:BUILD_V1; reject = $env:BUILD_V2 }
    )
    rollback          = [ordered]@{
        from         = $env:BUILD_V2
        to           = $env:BUILD_V1
        from_release = $releaseDeployed
        to_release   = $releaseActive
        ops          = 2
        ms           = [int]$env:ROLLBACK_MS
    }
}

# -Depth 5 perlu karena ConvertTo-Json default berhenti di kedalaman 2 dan akan
# mengubah array smoke jadi string "System.Collections.Hashtable".
$json = $result | ConvertTo-Json -Depth 5

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($OutFile, $json, $utf8NoBom)

Write-Host "==> metadata hasil run ditulis ke $OutFile"
Write-Host $json
