<#
.SYNOPSIS
  Baca physicalPath sebuah site IIS dengan benar, atau gagal keras.

.DESCRIPTION
  File ini ada karena satu bug yang mahal, dan sengaja didokumentasikan supaya tidak
  terulang.

  `(Get-ItemProperty "IIS:\Sites\demo" -Name physicalPath).Value` mengembalikan nilai
  KOSONG di runner windows-latest. Bukan error, bukan exception, hanya string kosong.
  Penyebabnya: untuk properti bertipe string, provider WebAdministration mengembalikan
  string itu langsung, bukan objek yang punya properti `.Value`. Dan `.Value` pada
  sebuah string menghasilkan $null.

  Akibatnya di run 40126812767: pemanggilnya menyangka site belum punya pointer, lalu
  jatuh ke fallback "tebak rilis bernomor tertinggi" dan menebak salah. Lock probe jadi
  menimpa folder yang tidak sedang dilayani, dan hasilnya salah dibaca sebagai cache
  http.sys. Ini jenis kegagalan paling berbahaya: diam, dan hasilnya kelihatan wajar.

  Aturan di sini: kalau pointer-nya tidak bisa dibaca, LEMPAR. Jangan menebak. Menebak
  itu yang membuat kesalahan tadi lolos sampai ke website.
#>

function Get-SitePhysicalPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SiteName
    )

    # Dicoba berurutan, dari yang paling stabil API-nya ke yang paling ringkas. Bentuk
    # kembalian ketiganya berbeda antar versi provider, jadi masing-masing dibungkus
    # try: yang gagal di satu versi justru yang jalan di versi lain.
    $attempts = @(
        # 1. Langsung dari applicationHost.config. Jalur yang paling tidak bergantung
        #    pada kebiasaan provider: physicalPath sebenarnya disimpan di
        #    virtualDirectory '/' milik application '/'.
        {
            (Get-WebConfigurationProperty `
                -Filter "/system.applicationHost/sites/site[@name='$SiteName']/application[@path='/']/virtualDirectory[@path='/']" `
                -Name physicalPath).Value
        },
        # 2. Lewat objek site dari provider.
        { (Get-Item "IIS:\Sites\$SiteName").physicalPath },
        # 3. Bentuk yang dulu dipakai, tapi TANPA .Value. Inilah yang sebenarnya benar
        #    untuk properti string, dan .Value itulah yang dulu menelannya jadi kosong.
        { Get-ItemProperty "IIS:\Sites\$SiteName" -Name physicalPath }
    )

    foreach ($attempt in $attempts) {
        try {
            $raw = & $attempt

            # Provider bisa mengembalikan string, bisa objek ber-.Value. Dua-duanya
            # dinormalkan di sini, supaya pemanggil tidak perlu tahu bedanya.
            $value = if ($raw -is [string]) {
                $raw
            } elseif ($raw -and $raw.PSObject.Properties['Value']) {
                $raw.Value
            } else {
                $null
            }

            if (-not [string]::IsNullOrWhiteSpace($value)) { return [string]$value }
        } catch {
            # Cara ini tidak tersedia di versi provider ini. Lanjut ke cara berikutnya.
        }
    }

    throw "tidak bisa membaca physicalPath site '$SiteName'. Sengaja tidak ditebak: perbaiki pembacaannya, jangan tambahkan fallback."
}
