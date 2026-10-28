# Slayer'da çalışır: Ekran.ipa'yı yeniden imzalayıp iPhone'a kurar.
# Telefon USB'deyse usbmux ile, değilse Wi-Fi üzerinden RemotePairing tüneliyle (engelci/araclar/wifi-kur.py, Slayer'da ipad-araclar içinde).
# Çıktının son satırı: KURULDU | YOK | HATA <ayrıntı>. oto-yenile.sh bunu okur.
$ProgressPreference = 'SilentlyContinue'; $env:RUST_LOG = 'warn'; $env:PYTHONIOENCODING = 'utf-8'
$v = 'C:\Users\AliR\ipad-araclar'; $ph = '00008110-001C0C621A0A401E'
$pmd = "$v\Scripts\pymobiledevice3.exe"
# Slayer evde ve klinikte farklı ağda; telefon hangi ağdaysa Slayer'ın o anki ağı taranır.
$ip = (Get-NetIPAddress -AddressFamily IPv4 | ? { $_.PrefixOrigin -eq 'Dhcp' -and $_.InterfaceAlias -notmatch 'Tailscale|vEthernet' } | Select-Object -First 1).IPAddress
$ag = ($ip -replace '\.\d+$', '.0') + '/24'

# Apple Devices usbmux'u kendiliğinden açılmıyor; dinlemiyorsa paketin içinden başlat.
if (-not (Get-NetTCPConnection -LocalPort 27015 -State Listen -ErrorAction SilentlyContinue)) {
    $pkg = Get-AppxPackage AppleInc.AppleDevices
    Invoke-CommandInDesktopPackage -PackageFamilyName $pkg.PackageFamilyName -AppId App `
        -Command "$($pkg.InstallLocation)\AppleMobileDeviceProcess.exe"
    Start-Sleep 8
}
$usb = ((& $pmd usbmux list 2>$null | Out-String) -match $ph)

& "$v\plumesign.exe" account switch dtalikabak@icloud.com *>&1 | Out-Null
Remove-Item "$v\Ekran2-signed.ipa" -ErrorAction SilentlyContinue
$imza = & "$v\plumesign.exe" sign --package "$v\Ekran.ipa" --apple-id -o "$v\Ekran2-signed.ipa" *>&1 | Out-String
if (-not (Test-Path "$v\Ekran2-signed.ipa")) {
    'HATA imza: ' + ($imza -replace '\s+', ' ').Substring([Math]::Max(0, $imza.Length - 300)); exit
}

if ($usb) {
    $o = & $pmd apps install --udid $ph "$v\Ekran2-signed.ipa" 2>&1 | Out-String
    if ($o -match 'Installation succeed') { 'KURULDU' }
    else { 'HATA kurulum: ' + ($o -replace '\s+', ' ').Substring([Math]::Max(0, $o.Length - 300)) }
    exit
}

# Wi-Fi: telefonun IP'si DHCP ile değişiyor, wifi-kur.py ağı tarayıp bulur.
$o = (& "$v\Scripts\python.exe" "$v\wifi-kur.py" $ag "$v\Ekran2-signed.ipa" 2>&1 | Out-String).Trim()
$son = ($o -split "`n")[-1].Trim()
if ($son -eq 'KURULDU') { 'KURULDU' }
elseif ($son -match 'telefon bulunamad') { 'YOK' }
else { 'HATA wifi: ' + $son }
