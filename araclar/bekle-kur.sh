#!/bin/bash
s=$HOME/projeler/ekran-yayin/araclar
for i in $(seq 1 120); do
  r=$($s/sps.sh < $s/kur.ps1 2>&1 | grep -v CLIXML | sed 's/_x000D__x000A_/\n/g' | grep -E 'YOK|KURULDU|HATA|Error|error' | head -5)
  case "$r" in
    *KURULDU*) dev-notify send --project ipad-muzik --title "Ekran Yayını iPhone'a kuruldu" --severity success --message "iPad hotspot'ta olsun. iPhone: Denetim Merkezi > ekran kaydına basılı tut > Ekran Yayını > Yayını Başlat. iPad: Ekran simgesi." >/dev/null; echo KURULDU; exit 0;;
    *YOK*) sleep 15;;
    *) echo "$r"; dev-notify send --project ipad-muzik --title "Ekran kurulumu hata" --severity error --message "$r" >/dev/null; exit 1;;
  esac
done
echo ZAMAN_ASIMI
