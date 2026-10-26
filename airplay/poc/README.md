# Araç Ekran — ölçüm denemesi
Derleme: `make -C /home/alir/projeler/ekran-yayin/airplay/poc` (8 iş).
Temizleme: `make -C poc clean`; çıktı: `build/aracekran` (imzalı armv7).
OpenSSL ve libplist statik bağlanır; GStreamer, görüntü ve ses çıkışı yoktur.
Dosyayı iPad'e `/var/mobile/aracekran` olarak aktarın, `chmod +x` uygulayın.
iPad'de root SSH oturumunda: `/var/mobile/aracekran [-s 1024x768] [-d]`.
iPhone ile aynı yerel ağa bağlanın, Ekran Yansıtma'dan “Araç Ekran”ı seçin.
Varsayılan ilan: 1280x720, maxFPS=30, refreshRate=30; port 7100.
HLS ve özellik biti 42 kapalıdır; şifre ve istemci kayıt denetimi yoktur.
Günlük: stdout ve `/var/mobile/Library/Logs/arac-airplay.log` (eklemeli).
Anahtar: `/var/mobile/Library/arac-airplay-key.pem`; çıkış: Ctrl-C/SIGTERM.
Codec/boyut callback'i, H264 SPS ve ilk/her 100. video tamponu yazılır.
Uyum: `uyum/ios9.h` endian ve iOS 9 CLOCK_REALTIME dönüşümlerini sağlar.
`sdkstub/`: libSystem'e `_memset_pattern16` ekler; libpthread aynı libSystem'i kullanır.
Bu UxPlay'de sistem Bonjour bağdaştırıcısı `lib/dns_sd/dns_sd.c` içindedir; cihaz testi yapılmadı.
