#!/bin/bash
set -e
s=$HOME/projeler/ekran-yayin/araclar
R=areis1643/ekran-yayin
id=$(gh run list -R $R -L 1 --json databaseId -q '.[0].databaseId')
until [ "$(gh run view $id -R $R --json status -q .status)" = completed ]; do sleep 15; done
[ "$(gh run view $id -R $R --json conclusion -q .conclusion)" = success ] || { echo DERLEME_HATA; gh run view $id -R $R --log-failed | grep -E 'error:' | head; exit 1; }
rm -rf $s/ipa3; mkdir -p $s/ipa3; gh run download $id -R $R -n ipa -D $s/ipa3
scp -q $s/ipa3/Ekran.ipa nilserver:/tmp/Ekran.ipa
ssh nilserver 'scp -q -i ~/.ssh/slayer_ed25519 -o IdentitiesOnly=yes /tmp/Ekran.ipa alir@100.101.69.89:C:/Users/AliR/ipad-araclar/Ekran.ipa && rm /tmp/Ekran.ipa'
$s/sps.sh <<'PS' 2>&1 | grep -v CLIXML | sed 's/_x000D__x000A_/\n/g' | grep -E 'IMZA|KURULDU|HATA|YOK' 
$ProgressPreference='SilentlyContinue'; $env:RUST_LOG='warn'
$v='C:\Users\AliR\ipad-araclar'; $ph='00008110-001C0C621A0A401E'
Remove-Item "$v\Ekran2-signed.ipa" -ErrorAction SilentlyContinue
& "$v\plumesign.exe" sign --package "$v\Ekran.ipa" --apple-id -o "$v\Ekran2-signed.ipa" 2>&1 | Out-Null
if (-not (Test-Path "$v\Ekran2-signed.ipa")) { "IMZA HATA"; exit }
$o = & "$v\Scripts\pymobiledevice3.exe" apps install --udid $ph "$v\Ekran2-signed.ipa" 2>&1 | Out-String
if ($o -match 'Installation succeed') { "KURULDU" } else { "HATA " + $o.Substring([Math]::Max(0,$o.Length-400)) }
PS
