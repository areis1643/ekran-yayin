# Slayer'da çalışır: Ekran.ipa'yı yeniden imzalayıp iPhone'a kurar (USB ya da ağ).
# Çıktının son satırı: KURULDU | YOK | HATA <ayrıntı>. oto-yenile.sh bunu okur.
$ProgressPreference = 'SilentlyContinue'; $env:RUST_LOG = 'warn'
$v = 'C:\Users\AliR\ipad-araclar'; $ph = '00008110-001C0C621A0A401E'
$pmd = "$v\Scripts\pymobiledevice3.exe"

# Apple Devices usbmux'u kendiliğinden açılmıyor; dinlemiyorsa paketin içinden başlat.
if (-not (Get-NetTCPConnection -LocalPort 27015 -State Listen -ErrorAction SilentlyContinue)) {
    $pkg = Get-AppxPackage AppleInc.AppleDevices
    Invoke-CommandInDesktopPackage -PackageFamilyName $pkg.PackageFamilyName -AppId App `
        -Command "$($pkg.InstallLocation)\AppleMobileDeviceProcess.exe"
    Start-Sleep 8
}

# Ağdaki cihazın görünmesi birkaç saniye sürebiliyor.
$gorundu = $false
for ($i = 0; $i -lt 6 -and -not $gorundu; $i++) {
    $gorundu = ((& $pmd usbmux list 2>$null | Out-String) -match $ph)
    if (-not $gorundu) { Start-Sleep 5 }
}
if (-not $gorundu) { 'YOK'; exit }

& "$v\plumesign.exe" account switch dtalikabak@icloud.com *>&1 | Out-Null
Remove-Item "$v\Ekran2-signed.ipa" -ErrorAction SilentlyContinue
$imza = & "$v\plumesign.exe" sign --package "$v\Ekran.ipa" --apple-id -o "$v\Ekran2-signed.ipa" *>&1 | Out-String
if (-not (Test-Path "$v\Ekran2-signed.ipa")) {
    'HATA imza: ' + ($imza -replace '\s+', ' ').Substring([Math]::Max(0, $imza.Length - 300)); exit
}
$o = & $pmd apps install --udid $ph "$v\Ekran2-signed.ipa" 2>&1 | Out-String
if ($o -match 'Installation succeed') { 'KURULDU' }
else { 'HATA kurulum: ' + ($o -replace '\s+', ' ').Substring([Math]::Max(0, $o.Length - 300)) }
