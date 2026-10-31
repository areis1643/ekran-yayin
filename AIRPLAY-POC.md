# AirPlay ekran yansıtma — kavram kanıtı (devir notu, 26 Ekim 2026)

Amaç: iPad 2'deki `Araç` uygulaması (iPad/main.m) iPhone'un yerleşik **Ekran Yansıtma**
özelliğinin alıcısı olsun. Bu belge yeni oturumun tek başına başlayabilmesi için yazıldı.

## Kavram kanıtının tek sorusu

iPhone (Ar3is'in, A15, iOS 27) iPad'e yansıtırken **H.264 mü HEVC mi** gönderiyor, hangi
çözünürlükte? iPad 2 (A5) yalnız H.264 çözebilir. HEVC gelirse **dur**, proje kapanır.
Bu adımda görüntü çizilmez: yalnız bulunma + el sıkışma + ilk yapılandırma paketini (tip 0x01,
SPS/PPS) günlüğe yazmak. SPS'ten profil/çözünürlük okunur.

## Neden bu yol (Ar3is kararı, 26 Ekim)

- Mevcut yol: iPhone'da ReplayKit eklentisi (Yayin/) → TCP 8889 → Araç. Çalışıyor (25–29 kare/sn)
  ama iPhone uygulaması ücretsiz hesapla 7 günde bir yeniden imza istiyor, yayın elle başlatılıyor,
  ses iki cihazdan çıkıyor (iPhone sesi kısılarak çözülüyor).
- AirPlay **ses** (AirSpeaker) iPad'de çalışıyor: iPhone iPad'i hotspot ağında buluyor, kilitte
  çalıyor, senkron sorunu yok. Görüntüyü de aynı yoldan almak hedef.
- Kazanılmayacak: iPhone kilitlenince yansıtma da duruyor; arama sesi iPhone'da kalıyor.

## Kaynak: UxPlay (github.com/FDH2/UxPlay)

- Bakımda; 1.73.7 (4 Eylül 2026) iOS 27 TEARDOWN düzeltmesi içeriyor. RPiPlay 2022'den beri ölü.
- Çekirdek `lib/`: pthread, OpenSSL (libcrypto: EVP, RAND, PEM, SHA), libplist, gömülü playfair
  (FairPlay), llhttp. GStreamer yalnız oynatıcı katmanında, alınmayacak.
- Geri çağırmalar `lib/raop.h` → `raop_callbacks_t` (`video_process`, `audio_process`,
  `video_set_codec_and_size` …). Video verisi `lib/stream.h` `video_decode_struct`.
- `lib/raop_rtp_mirror.c`: şifre çözülmüş yük AVCC; çekirdek uzunlukları `00 00 00 01` yapıp
  Annex-B verir. SPS/PPS ayrı, şifresiz tip 0x01 paketinde. Callback dönünce tampon serbest
  bırakılıyor: asenkron çözücüye verilecekse kopyala.
- "type 0x01 packet with no payload" = H.264 dışı codec (UxPlay #535). Bir iOS 27 beta iPhone 15 Pro
  HEVC gönderdi; iPadOS 27 beta 5 H.264 ile sorunsuz. Bizim iPhone bilinmiyor → kavram kanıtı bunu ölçer.
- `/info` yanıtında `displays[].widthPixels/heightPixels/maxFPS` (UxPlay `-s 1280x720 -fps 30`)
  gönderene istenen boyutu bildirir. iPad 2 için 1024x768 ya da 1280x720 iste. Seçenekte
  H.265'i **ilan etme** (features bit 42 SupportsScreenMultiCodec kapalı).
- Bulunma: iOS'un kendi `dns_sd` (DNSServiceRegister) API'si iPad'de var; Avahi gerekmez.
  `_airplay._tcp` ve `_raop._tcp` ilanları.

## Ortam

- iPad derleme: theos `~/theos`, iOS 9.3 SDK, armv7, `iPad/Makefile` (Araç uygulaması + `aracbaslat`
  aracı). `sdkstub/libSystem.tbd` olmadan bağlanmaz. Derleme:
  `cd iPad && THEOS=~/theos make package FINALPACKAGE=1` ("building for iOS Simulator" uyarıları normal).
- Çapraz derlenecek: OpenSSL (armv7, iOS 9 en düşük sürüm; `ios-cross` hedefi), libplist, llhttp.
  playfair kaynak olarak gömülü.
- Kurulum (iPad Slayer'a USB ile takılı): deb'i nilserver üstünden Slayer'a scp, sonra `araclar/sps.sh`
  ile PowerShell: `pymobiledevice3 usbmux forward --serial bf79db1054b82247babaeefca859934295210c7b 2222 22`
  (iki cihaz takılıyken `--serial` şart) + `ipssh.py put` + `ipssh.py "cd /; dpkg -i …"`.
  Örnek: oturum geçmişinde ve `🧠 500-Knowledge/ipad-muzik/ipad-muzik.md`.
- iPad'de `tail`, `cut`, `ifconfig` yok. Syslog USB'den açılmıyor: tanıyı dosyaya yaz
  (ör. `/var/mobile/Library/Logs/arac-airplay.log`) ve SSH ile oku.
- AirSpeaker iPad'de çalışıyor ve `_raop._tcp` ilan ediyor. Ad çakışmasına dikkat (ayrı ad kullan,
  ör. "Araç Ekran"); gerekirse kavram kanıtı sırasında AirSpeaker durdurulur:
  `launchctl unload /Library/LaunchDaemons/net.angelxwind.airspeaker.plist`.
- Test ağı: iPad iPhone hotspot'unda (172.20.10.x). Ev modemi Wi-Fi'de multicast geçirmiyor, evde
  bulunma testi yapılamaz; hotspot'ta Bonjour geçiyor (AirSpeaker ile doğrulandı).

## Önerilen sıra

1. UxPlay'i klonla, `lib/` bağımlılık listesini doğrula.
2. OpenSSL + libplist + llhttp'yi armv7/iOS 9 için statik derle (işçi işi).
3. `iPad/` altına ayrı bir deneme aracı (tool) ya da Araç içine: dns_sd ilanı + raop sunucusu,
   `video_process` ilk çağrısında / tip 0x01 paketinde codec, SPS profil ve çözünürlüğü günlüğe yaz.
4. iPad'e kur, Ar3is hotspot'ta Denetim Merkezi → Ekran Yansıtma → bu adı seçsin, günlüğü oku.
5. H.264 → görüntüyü Araç'ın mevcut AVSampleBufferDisplayLayer yoluna bağla. HEVC → dur, kaydet.

Kural: görsel tasarım değişikliği önce Telegram'dan (dev-notify --file) onaya gider. Kod yazımı
DELEGE kurallarıyla işçilere (sol-amele / deepseek-amele) verilir, ana oturum denetler.

## Sonuç (26 Ekim 2026, 03:12) — H.264, devam

`airplay/poc/aracekran` iPad'de (hotspot) ölçtü; iPhone14,3, iOS 27.0.1, AirPlay/980.77.1:
- `video_set_codec_and_size codec=H264`, ilk pakette SPS+PPS (Annex-B, `27 64 00 1e`).
- SPS: **High profil (100), level 3.0**, 4:2:0, progresif. Dikey telefonda 334x720
  (1280x720 ilanın içine x_offset=473 ile yerleşiyor). iPad 2 A5 High profili çözer.
- HEVC gelmedi (features bit 42 kapalıyken).
- Tuzak: Denetim Merkezi'nin ses listesinden seçilince yalnız `type 96` ses akışı açılıyor
  (`TEARDOWN 96=1, 110=0`); yansıtma yalnız Ekran Yansıtma düğmesinden (`isScreenMirroringSession`,
  `type 110`).
- Araç zinciri: `airplay/build-openssl.sh` (1.1.1w), `airplay/build-libplist.sh` (2.8.0),
  `make -C airplay/poc`; iPad'e `araclar/ipad.sh put` + `sh /var/mobile/baslat.sh -d`.
  SDK .tbd'lerinde memcpy/memset vb. eksik; `airplay/poc/sdkstub/` yamalı stub'ı kullanır.

Sıradaki: 5. adım — `video_process` Annex-B kareleri Araç'ın AVSampleBufferDisplayLayer yoluna.

## 5. adım sonucu (26 Ekim 2026) — görüntü çalışıyor, ses bizim daemon'da

- `aracairplay` daemon'u + Araç'ın ikinci kaynağı (commit f7e3149): Ar3is'in denemesinde
  "kusursuza yakın", gecikme hissedilmiyor; dik 356x768, yatay 1024x474.
- Ses: yansıtma sürerken iOS ses çıkışını AirSpeaker'a seçtiriyor ama o anda yansıtma
  kopuyor (Ar3is denedi). Bu yüzden ses daemon'da çözülüp Araç'a 'A' paketiyle gidiyor
  (AudioConverter; ct=8 AAC-ELD, ct=4 AAC-LC, ct=2 ALAC). Tuzak: çözücü besleme geri
  çağırmasında "0 paket + noErr" akış sonu sayılır, sonra çözücü çıktı vermez; ayrı bir
  durum kodu döndürülmeli.
- AirSpeaker (armv7 ikilisi, yalnız string/sembol taraması): ALAC'ı AudioConverter ile
  `frma`+`alac` atomlu çerezle çözüyor, çıkışı AudioUnit (mixer + varispeed) ile yapıyor,
  RTP zaman damgasıyla senkron ve yeniden isteme var; imzada yalnız `platform-application`.
- Ses ölçümü: yansıtmada ct=8 AAC-ELD (spf 480), ham AudioSpecificConfig çerezi kabul
  edildi; yalnız ses (müzik) oturumunda ct=2 ALAC, 24 baytlık ALACSpecificConfig yetti.
  Ar3is: ses-görüntü senkronu "mükemmel", hata=0.
- Açık: daemon üç kez (03:31, 03:35, 03:59) rapor bırakmadan yeniden başladı; çökme
  yakalayıcı da hiçbir şey yazmadı → yakalanamayan SIGKILL. tahmin: jetsam bellek sınırı
  (GOP önbelleği 2-4 MB + realloc). plist'e JetsamProperties (öncelik 18, 96 MB) eklendi;
  etkisi henüz doğrulanmadı.

## 6. adım (26 Ekim 2026) — ses daemon'da, kilitte çalışıyor

- Ses artık Araç'ta değil aracairplay'de çalıyor (AirSpeaker yöntemi: mobile kullanıcısı,
  platform-application, AVAudioSession Playback + MixWithOthers, RemoteIO). Ar3is: iPhone
  kilitlenince ses sürüyor, kilit açılınca yansıtma kendiliğinden devam ediyor; iPad
  kilitliyken de ses geliyor; senkron kusursuz.
- Yansıtma başlayınca daemon Araç'ı SBSLaunchApplicationWithIdentifier ile açıyor.
- Tuzak: iPad kilitliyken Araç askıda; dönünce GOP yeniden oynatımı aradaki görüntüyü
  hızlandırılmış gösteriyordu. 'F' bayrak baytında bit 1 = gösterme; son kare dışındaki
  yeniden oynatılan kareler kCMSampleAttachmentKey_DoNotDisplay ile yalnız çözülüyor.
- Ar3is doğruladı (04:3x): Araç yansıtmayla kendiliğinden açılıyor; iPad kilidinden dönüşte
  hızlandırma 10-15 sn'den bir iki ana indi (kalan: Araç'ın soket tamponundaki canlı
  kareler). iPad ekranı arabada hep açık kalacağı için bu kadarı kabul edildi.

## 7. adım (26 Ekim 2026) — video oynarken daemon'un sessiz ölümü

- Belirti: YouTube videosu bir süre oynayınca yansıtma kapanıyor (2x'te daha çabuk), müzikte
  yok. Ölen Araç değil aracairplay: 13:38'de pid değişti, rapor yok, COKTU yok.
- Ölçüm (memorystatus GET_PRIORITY_LIST, root): daemon öncelik 0, sınır 5 MB. plist'teki
  JetsamProperties (18 / 96 MB) iOS 9'da /Library/LaunchDaemons için yok sayılıyor.
  GOP önbelleği 2-4 MB'a çıkınca (video) ya da bellek baskısında boşta bandındaki daemon
  ilk öldürülen oluyordu. Gece 03:31/03:35/03:59 yeniden başlamaları da bu.
- Düzeltme: daemon root başlar, memorystatus_control ile kendine öncelik 15 / 64 MB koyar,
  sonra mobile'a (501) iner. Günlükte "jetsam oncelik=0 sinir=0 uid=501" = ikisi de başarılı.
  Cihazda doğrulandı: öncelik 15, sınır 64 MB. Video ile uzun deneme bekliyor.

## 8. adım (28 Ekim 2026) — zaman damgalı ses-görüntü senkronu

- Belirti (27 Ekim, arabada): 2x videoda ses ile görüntü senkronu "zorlanıyor".
- Kodda bulunan: UxPlay'in verdiği `ntp_time_local` hiç kullanılmıyordu. Kare geldiği an
  (DisplayImmediately) gösteriliyor, ses geldiği an çalınıyordu. Bluetooth hoparlör (thinkplus,
  26 Ekim akşamından beri kendiliğinden bağlanıyor) sese ~150-250 ms ekler, bu telafi edilmiyordu;
  AirPlay karesi hiç atılmadığı için çözücü yetişemezse görüntü gecikmesi birikiyordu.
- Düzeltme: daemon kareye ve sese aynı oynatma gecikmesini ekler (gelişteki gecikme + Araç payı
  60 ms / hoparlör outputLatency + 30 ms; en az 80, en çok 800 ms; artışı anında, inişi 2 sn'de
  10 ms). 'F' bayrağında bit 2 = ardından 8 bayt gösterim zamanı (gettimeofday ns); Araç
  katmanına bu saati izleyen controlTimebase verildi. Ses RemoteIO'da duyulma zamanına göre
  geç kalan atılır, erken gelen bekletilir. Yalnız ses (müzik) oturumu eskisi gibi hemen çalar.
- Ölçüm günlükte: "son 30 sn senkron: ..." satırı ve "ses cikisi: ..." (rota + gecikme).
  Cihazda henüz denenmedi.
- 27 Ekim günlüğü (yedek iPad'de `/var/mobile/arac-airplay-yedek-1028.log`): 19:50 oturumunda
  Araç açılamadı (SBS sonucu 3), Araç 3 dk sonra bağlandı ve 1688 karelik (5 MB) GOP yeniden
  oynatıldı; tek GOP 13 dk'da 16 MB sınırına yaklaştı (iPhone IDR'yi çok seyrek yolluyor).
  19:55-19:58 arası 3646 kez "raop_rtp resend failed: 55" (ENOBUFS). Düzeltme: yansıtma
  sürerken Araç bağlı değilse daemon 5 sn'de bir yeniden açmayı dener.
- 28 Ekim 12:35 kuruldu; daemon ayağa kalktı (iPad hoparlörü, çıkış gecikmesi 25 ms). Yansıtma
  ile deneme hotspot'ta bekliyor.

## 9. adım (31 Ekim 2026) — iPhone "Araç Ekran"ı seçiyor, bağlantı daemon'a hiç gelmiyor

- Belirti: arabada ve evde, iPhone listede Araç Ekran'ı görüyor, seçince bağlanmıyor. Daemon
  günlüğünde iz yoktu; UxPlay'in bağlantı satırları INFO'daydı (b0b55f4 ile yazılıyor).
- `araclar/kokla/` (iPad'de BPF ile paket özeti, tcpdump yok) gösterdi: iPhone yalnız IPv6
  link-local (fe80::…:7100) ile SYN yolluyor, iPad cevap vermiyor. iPhone'dan gelen IPv6 TCP
  paketlerinin sağlama toplamı bozuk (ör. ffe1, 0xffff olmalı), IPv4 paketleri temiz. iPad
  çekirdeği bozuk paketi sessizce atıyor; iPad'den iPhone'a IPv6 bağlantısında da aynısı.
  Daemon IPv6'da dinliyor (yerelden [fe80::…%en0]:7100 bağlandı), pf kapalı.
- iPad'de `ipconfig set en0 NONE-V6` tek başına yetmedi: iPhone A kaydını aldı ama IPv4'le
  denemedi (iPhone o sırada takılı durumdaydı; geri alındı: AUTOMATIC-V6).
- iPhone yeniden başlatılınca yansıtma IPv4'le (172.20.10.1 -> .13) hemen başladı. IPv6
  toplamları yeniden başlatmadan sonra da bozuk; yani düzelen IPv6 değil, iPhone'un IPv4'ü
  seçmesi. Tekrarlarsa ilk çare iPhone'u yeniden başlatmak; kalıcı çözüm için açık: iPad
  erişim noktasındayken IPv6'yı kapatmak (root gerekir, aracbaslat mobile kullanıcısında).
