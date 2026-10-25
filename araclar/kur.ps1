$ProgressPreference='SilentlyContinue'
$v='C:\Users\AliR\ipad-araclar'
$ph='00008110-001C0C621A0A401E'
$l = & "$v\Scripts\pymobiledevice3.exe" usbmux list 2>$null | Out-String
if ($l -notmatch $ph) { "YOK"; exit }
& "$v\Scripts\pymobiledevice3.exe" apps uninstall --udid $ph dev.jdkula.Wingspan.RC7HJZJ33B 2>&1 | Out-Null
$o = & "$v\Scripts\pymobiledevice3.exe" apps install --udid $ph "$v\Ekran2-signed.ipa" 2>&1 | Out-String
if ($o -match 'Installation succeed') { "KURULDU" } else { "HATA"; $o.Substring([Math]::Max(0,$o.Length-600)) }
