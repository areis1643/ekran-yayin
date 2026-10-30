#!/bin/bash
# Yansıtma deneme döngüsü: iPad Slayer'a kabloyla takılı, iPad iPhone'un erişim noktasında.
#   dene.sh            derle + kur + yansıtmayı bekle + ölç + teşhis
#   dene.sh --kurma    kurmadan yalnız bekle + ölç (yüklü sürümü dener)
# Günlükler denemeden önce iPad'de /var/mobile/arac-*-yedek-<tarih>.log olarak saklanır,
# teşhis dosyaları buraya iner: $CIKTI
set -u
burada=$(cd "$(dirname "$0")" && pwd)
kok=$(dirname "$burada")
ipad() { timeout 120 "$burada/ipad.sh" "$@"; }
CIKTI=${CIKTI:-$HOME/.local/state/ekran-dene}
mkdir -p "$CIKTI"
AP=/var/mobile/Library/Logs/arac-airplay.log
UY=/var/mobile/Library/Logs/arac-uygulama.log
BEKLE=${BEKLE:-300}   # yansıtmanın başlaması için en çok bu kadar sn
kur=1
[ "${1:-}" = --kurma ] && kur=0

bildir() { dev-notify send --project ipad-muzik --title "$1" --message "$2" --severity "${3:-info}" >/dev/null 2>&1 || true; }
adim() { printf '\n== %s\n' "$*"; }

adim "iPad'e ulaşılıyor"
c=$(ipad 'echo HAZIR' 2>&1)
case "$c" in
  *HAZIR*) echo "iPad hazır" ;;
  *IPAD_YOK*) echo "Slayer iPad'i görmüyor: kabloyu çıkarıp tak, iPad'in kilidini aç, 'Güven' çıkarsa onayla."; exit 1 ;;
  *) echo "iPad'e ulaşılamadı:"; printf '%s\n' "$c" | tail -3; exit 1 ;;
esac

adim "Günlükler yedekleniyor ve sıfırlanıyor"
ipad "d=\$(date +%m%d-%H%M); cp $AP /var/mobile/arac-airplay-yedek-\$d.log; cp $UY /var/mobile/arac-uygulama-yedek-\$d.log 2>/dev/null; : > $AP; : > $UY; chown mobile:mobile $UY; echo yedek \$d" | grep yedek

if [ $kur = 1 ]; then
  adim "Derleniyor"
  rm -f "$kok"/iPad/packages/*.deb
  (cd "$kok/iPad" && THEOS=$HOME/theos make package FINALPACKAGE=1 >"$CIKTI/derleme.log" 2>&1) || { echo "derleme hatası, $CIKTI/derleme.log"; grep -E 'error' "$CIKTI/derleme.log" | head; exit 1; }
  deb=$(ls "$kok"/iPad/packages/*.deb)
  adim "Kuruluyor"
  ipad put "$deb" /var/mobile/arac.deb | grep -q 'PUT ok' || { echo "paket iPad'e gitmedi"; exit 1; }
  c=$(ipad 'dpkg -i /var/mobile/arac.deb >/dev/null 2>&1 && echo KURULDU; killall Arac 2>/dev/null; sleep 2; ps ax | grep -E "libexec/arac(airplay|baslat)" | grep -v grep')
  printf '%s\n' "$c" | grep -q KURULDU || { echo "dpkg başarısız"; printf '%s\n' "$c"; exit 1; }
  printf '%s\n' "$c" | grep -q aracairplay || { echo "aracairplay ayağa kalkmadı"; printf '%s\n' "$c"; exit 1; }
  echo "kuruldu, servisler çalışıyor"
fi

adim "Yansıtma bekleniyor (en çok $BEKLE sn)"
echo "iPhone: Denetim Merkezi > Ekran Yansıtma > Araç Ekran. iPad erişim noktasında olsun."
bildir "iPad hazır, yansıtmayı başlat" "iPhone: Denetim Merkezi > Ekran Yansıtma > Araç Ekran. Gerisini ben ölçüyorum."
bas=$(date +%s); basladi=0
while [ $(( $(date +%s) - bas )) -lt "$BEKLE" ]; do
  if ipad "grep -c 'mirror ba' $AP" | grep -q '^[1-9]'; then basladi=1; break; fi
  sleep 10
done
if [ $basladi = 0 ]; then
  ipad "cat $AP" | tr -d '\r' > "$CIKTI/airplay.log"
  if grep -q 'iPhone bağlandı' "$CIKTI/airplay.log"; then
    echo "TEŞHİS: iPhone bağlandı ama Ekran Yansıtma başlamadı (ses listesinden seçilmiş olabilir; Ekran Yansıtma düğmesinden seç)."
  else
    echo "TEŞHİS: iPhone daemon'a hiç ulaşmadı. iPad erişim noktasında mı? (Ev modemi Bonjour geçirmiyor, Araç Ekran yalnız erişim noktasında görünür.)"
  fi
  exit 2
fi

adim "Yansıtma başladı, 70 sn ölçülüyor"
sleep 70
ipad "cat $AP" | tr -d '\r' > "$CIKTI/airplay.log"
ipad "cat $UY" | tr -d '\r' > "$CIKTI/uygulama.log"

d_kare=$(grep -a 'son 30 sn: ' "$CIKTI/airplay.log" | tail -1 | sed -n 's/.*son 30 sn: \([0-9]*\) kare.*/\1/p')
d_arac=$(grep -a 'son 30 sn: ' "$CIKTI/airplay.log" | tail -1 | sed -n 's/.*Araç \([^ ]*\)$/\1/p')
d_ses=$(grep -a 'son 30 sn ses: ' "$CIKTI/airplay.log" | tail -1 | sed -n 's/.*paket=\([0-9]*\).*/\1/p')
u=$(grep -a '10 sn: ' "$CIKTI/uygulama.log" | tail -1)
u_gelen=$(printf '%s' "$u" | sed -n 's/.*gelen kare \([0-9]*\).*/\1/p')
u_giren=$(printf '%s' "$u" | sed -n 's/.*katmana giren \([0-9]*\).*/\1/p')
u_durum=$(printf '%s' "$u" | sed -n 's/.*katman durum=\([0-9]*\).*/\1/p')
u_ekran=$(printf '%s' "$u" | sed -n 's/.*ekranda=\([0-9]*\).*/\1/p')

adim "Ölçüm"
echo "daemon (son 30 sn): ${d_kare:-?} kare, ${d_ses:-?} ses paketi, Araç ${d_arac:-?}"
echo "Araç   (son 10 sn): gelen ${u_gelen:-?} kare, katmana giren ${u_giren:-?}, katman durumu ${u_durum:-?} (1 = çiziyor, 2 = hata), ön planda ${u_ekran:-?}"
grep -a -E 'senkron:' "$CIKTI/airplay.log" | tail -1 | sed 's/^[^ ]* [^ ]* /daemon senkron: /'

adim "Teşhis"
if [ "${d_kare:-0}" = 0 ]; then
  t="iPhone görüntü yollamıyor (daemon 0 kare). Ekran durağan olabilir; iPhone'da bir şey kaydırıp tekrar dene."
elif [ "${d_arac:-}" != "bağlı" ]; then
  t="Daemon kare alıyor ama Araç bağlı değil: iPad kilitli ya da Araç açılamadı."
elif [ -z "$u" ]; then
  t="Araç tanı satırı yazmadı: Araç eski sürüm ya da çalışmıyor."
elif [ "${u_gelen:-0}" = 0 ]; then
  t="Daemon yolluyor ama Araç kare almıyor: yerel bağlantı (127.0.0.1:7101) sorunu."
elif [ "${u_giren:-0}" = 0 ]; then
  t="Araç kareyi alıp katmana vermiyor: anahtar kare bekliyor (iPhone IDR'yi seyrek yolluyor) ya da kaynak seçimi."
elif [ "${u_durum:-0}" = 2 ]; then
  t="Katman çözme hatası: $(printf '%s' "$u" | sed -n 's/.*hata=\(.*\); ekranda.*/\1/p')"
elif [ "${u_ekran:-0}" = 0 ]; then
  t="Kareler katmana giriyor ama Araç ön planda değil."
else
  t="Zincir sağlam: iPhone > daemon > Araç > katman akıyor (${u_giren} kare/10 sn). Ekranda görüntü yoksa söyle, sorun çizimde."
fi
echo "$t"
bildir "Yansıtma denemesi" "$t"
echo "günlükler: $CIKTI/airplay.log $CIKTI/uygulama.log"
