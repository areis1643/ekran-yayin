#!/bin/bash
# iPad'e (Slayer'a USB ile takılı) SSH komutu ya da dosya gönderir.
#   ipad.sh "komut"            iPad'de root olarak çalıştırır
#   ipad.sh put yerel uzak     dosyayı nilserver -> Slayer -> iPad yoluyla yollar
# iPad görünmüyorsa önce Apple usbmux servisini açar, gerekirse USB aygıtını yeniden
# başlatır; yine yoksa çıktı IPAD_YOK olur.
set -e
UDID=bf79db1054b82247babaeefca859934295210c7b
V='C:\Users\AliR\ipad-araclar'
burada=$(dirname "$0")

if [ "$1" = put ]; then
  ad=$(basename "$2")
  scp -q "$2" nilserver:/tmp/"$ad"
  ssh nilserver "scp -q -i ~/.ssh/slayer_ed25519 -o IdentitiesOnly=yes /tmp/$ad alir@100.101.69.89:ipad-araclar/$ad && rm /tmp/$ad"
  ic="& \"$V\\Scripts\\python.exe\" \"$V\\ipssh.py\" put \"$V\\$ad\" '$3'"
else
  komut=${1//\'/\'\'}
  # Windows PowerShell 5, yerel programa geçen argümandaki çift tırnağı yutuyor.
  komut=${komut//\"/\\\"}
  ic="& \"$V\\Scripts\\python.exe\" \"$V\\ipssh.py\" '$komut'"
fi

"$burada/sps.sh" <<EOF 2>/dev/null | grep -a -v -e '^#< CLIXML' -e '^<Objs'
\$ProgressPreference='SilentlyContinue'; \$env:PYTHONIOENCODING='utf-8'
\$pmd = "$V\\Scripts\\pymobiledevice3.exe"
function gorunuyor { (& \$pmd usbmux list 2>\$null | Out-String) -match '$UDID' }
# 30 Eki: iPad takılıydı ama Apple servisi kapalıydı; açınca da önceden takılı iPad'i
# listeye almadı, USB aygıtını yeniden başlatmak gerekti.
if (-not (Get-NetTCPConnection -LocalPort 27015 -State Listen -ErrorAction SilentlyContinue)) {
    \$pkg = Get-AppxPackage AppleInc.AppleDevices
    Invoke-CommandInDesktopPackage -PackageFamilyName \$pkg.PackageFamilyName -AppId App -Command "\$(\$pkg.InstallLocation)\\AppleMobileDeviceProcess.exe"
    Start-Sleep 8
}
if (-not (gorunuyor)) {
    Get-PnpDevice -PresentOnly | ? { \$_.InstanceId -match '^USB\\\\VID_05AC' -and \$_.InstanceId -match '$UDID' } | % { pnputil /restart-device "\$(\$_.InstanceId)" | Out-Null }
    Start-Sleep 8
}
if (-not (gorunuyor)) { 'IPAD_YOK'; exit }
\$f = Start-Process -PassThru -WindowStyle Hidden \$pmd -ArgumentList 'usbmux','forward','--serial','$UDID','2222','22'
Start-Sleep -Seconds 3
try { $ic 2>&1 | Out-String } finally { Stop-Process -Id \$f.Id -Force -ErrorAction SilentlyContinue }
EOF
