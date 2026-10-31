#!/bin/sh
# Açılışta etkinleştirme kaydı kaybolmuşsa yedekten geri koyar.
# 31 Eki 2026: pil tamamen bitince kayıt yok oldu, iPad kurulum ekranında kaldı; dokunmatik
# bozuk olduğu için ekrandan geçilemiyor. Yedek: /var/root/aktivasyon-yedek (elle alındı).
K=/private/var/containers/Data/System/357A37CB-F0EA-41B9-9FCB-18E574BC1487/Library
Y=/var/root/aktivasyon-yedek
G=/var/mobile/Library/Logs/arac-aktivasyon.log
yaz() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> $G; }

[ -s $Y/activation_record.plist ] || { yaz "yedek yok, cikiliyor"; exit 0; }
if [ -s $K/activation_records/activation_record.plist ]; then
    yaz "kayit yerinde"
    exit 0
fi
yaz "kayit YOK, yedekten geri konuyor"
mkdir -p $K/activation_records
cp $Y/activation_record.plist $K/activation_records/activation_record.plist
chown mobile:nobody $K/activation_records $K/activation_records/activation_record.plist
chmod 777 $K/activation_records
chmod 666 $K/activation_records/activation_record.plist
if [ ! -s $K/internal/data_ark.plist ] && [ -s $Y/data_ark.plist ]; then
    cp $Y/data_ark.plist $K/internal/data_ark.plist
    chown nobody:nobody $K/internal/data_ark.plist
    chmod 000 $K/internal/data_ark.plist
    yaz "data_ark da geri kondu"
fi
# Servis kaydı yeniden okusun, kurulum ekranı kapansın.
sleep 5
killall -9 mobileactivationd
sleep 5
# Kurulum ekranı bir kez açılınca purplebuddy'de SetupDone=false yazıyor; respring
# bunu görüp ekranı geri getiriyor (31 Eki testi). SetupDone=true kopyası geri konur.
killall -9 Setup
P=/var/mobile/Library/Preferences/com.apple.purplebuddy.plist
if [ -s $Y/com.apple.purplebuddy.plist ]; then
    cp $Y/com.apple.purplebuddy.plist $P
    chown mobile:mobile $P
    chmod 600 $P
    killall -9 cfprefsd
    sleep 2
fi
killall -9 SpringBoard
yaz "mobileactivationd, purplebuddy ve SpringBoard yenilendi"
