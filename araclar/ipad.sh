#!/bin/bash
# iPad'e (Slayer'a USB ile takılı) SSH komutu ya da dosya gönderir.
#   ipad.sh "komut"            iPad'de root olarak çalıştırır
#   ipad.sh put yerel uzak     dosyayı nilserver -> Slayer -> iPad yoluyla yollar
set -e
UDID=bf79db1054b82247babaeefca859934295210c7b
V='C:\Users\AliR\ipad-araclar'
SLAYER='ssh -i ~/.ssh/slayer_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 alir@100.101.69.89'
burada=$(dirname "$0")

if [ "$1" = put ]; then
  ad=$(basename "$2")
  scp -q "$2" nilserver:/tmp/"$ad"
  ssh nilserver "scp -q -i ~/.ssh/slayer_ed25519 -o IdentitiesOnly=yes /tmp/$ad alir@100.101.69.89:ipad-araclar/$ad && rm /tmp/$ad"
  ic="& \"$V\\Scripts\\python.exe\" \"$V\\ipssh.py\" put \"$V\\$ad\" '$3'"
else
  komut=${1//\'/\'\'}
  ic="& \"$V\\Scripts\\python.exe\" \"$V\\ipssh.py\" '$komut'"
fi

"$burada/sps.sh" <<EOF 2>/dev/null | grep -a -v -e '^#< CLIXML' -e '^<Objs'
\$ProgressPreference='SilentlyContinue'
\$f = Start-Process -PassThru -WindowStyle Hidden "$V\\Scripts\\pymobiledevice3.exe" -ArgumentList 'usbmux','forward','--serial','$UDID','2222','22'
Start-Sleep -Seconds 3
try { $ic 2>&1 | Out-String } finally { Stop-Process -Id \$f.Id -Force -ErrorAction SilentlyContinue }
EOF
