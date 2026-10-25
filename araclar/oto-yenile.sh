#!/bin/bash
# nilserver'da zamanlayıcıyla çalışır. Ücretsiz Apple hesabı imzası 7 gün geçerli;
# son başarılı kurulumdan 5 gün geçtiyse Slayer üstünden yeniden imzalatıp kurar.
# iPhone o an ağda/USB'de yoksa bir sonraki koşuda tekrar dener.
set -u
STATE=$HOME/.local/state/ekran-yenile
mkdir -p "$STATE"
SON=$STATE/son-basari
ESIK=$((5 * 86400))
simdi=$(date +%s)
son=$(cat "$SON" 2>/dev/null || echo 0)
yas=$((simdi - son))

if [ "${1:-}" != "--zorla" ] && [ "$yas" -lt "$ESIK" ]; then
    echo "atlandi: son basari $((yas / 3600)) saat once"
    exit 0
fi

betik=$(dirname "$(readlink -f "$0")")/yenile.ps1
enc=$(iconv -f UTF-8 -t UTF-16LE "$betik" | base64 -w0)
cikti=$(timeout 600 ssh -i ~/.ssh/slayer_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=15 \
    alir@100.101.69.89 powershell -NoProfile -EncodedCommand "$enc" 2>&1)
kod=$?
sonuc=$(printf '%s\n' "$cikti" | grep -v CLIXML | sed 's/_x000D__x000A_/ /g' | grep -E '^(KURULDU|YOK|HATA)' | tail -1)
echo "ssh=$kod sonuc=${sonuc:-bos}"

gun_kaldi=$(( (7 * 86400 - yas) / 86400 ))
case "$sonuc" in
KURULDU)
    echo "$simdi" > "$SON"
    dev-notify send --project ipad-muzik --title "Ekran imzası yenilendi" \
        --message "iPhone'da Ekran 7 gün daha geçerli. Yayın açıksa durdurup yeniden başlat." --severity success ;;
HATA*)
    dev-notify send --project ipad-muzik --title "Ekran imza yenileme hatası" \
        --message "$sonuc (~${gun_kaldi} gün kaldı)" --severity error
    exit 1 ;;
*)
    # YOK ya da Slayer'a ulaşılamadı (kapalı, iPhone ağda değil): imzanın son gününe
    # kadar sessiz kal, sonraki koşu tekrar dener.
    if [ "$yas" -ge $((6 * 86400)) ]; then
        dev-notify send --project ipad-muzik --title "Ekran imzası bitiyor" \
            --message "Yenilenemedi (${sonuc:-Slayer erişilemedi}), ~${gun_kaldi} gün kaldı. iPhone'u Slayer'a tak ya da aynı ağa al." \
            --severity warning
    fi ;;
esac
