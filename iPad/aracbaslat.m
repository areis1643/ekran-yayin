#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <ifaddrs.h>
#import <netinet/in.h>
#import <signal.h>
#import <stdbool.h>
#import <sys/sysctl.h>
#import <unistd.h>

typedef int (*UygulamaAc)(CFStringRef identifier, Boolean suspended);
typedef int (*SecenekliAc)(CFStringRef identifier, CFURLRef url, CFDictionaryRef parametre, CFDictionaryRef secenek, Boolean suspended);

#pragma mark - Uykuyu engelleme

// Kilitli iPad'de işlemci uyuyunca döngü duruyor, ne iPhone'u ne hotspot'u arıyordu.
// Bu engel yalnız sistem uykusunu tutar; ekran her zamanki gibi kararır.
typedef uint32_t IOPMAssertionID;
extern int IOPMAssertionCreateWithName(CFStringRef tur, uint32_t duzey, CFStringRef ad, IOPMAssertionID *kimlik);

static void uykuyuEngelle(void) {
    IOPMAssertionID kimlik = 0;
    int sonuc = IOPMAssertionCreateWithName(CFSTR("PreventUserIdleSystemSleep"), 255, CFSTR("aracbaslat"), &kimlik);
    NSLog(@"aracbaslat uyku engeli: %d", sonuc);
}

#pragma mark - Hotspot'a kendiliğinden bağlanma

// iOS 9 iPhone erişim noktasını kayıtlı ağ olarak bilse de kendiliğinden katılmıyor;
// Ayarlar > Wi-Fi'den elle seçmek gerekiyordu. Wi-Fi boştayken tarayıp kendimiz katılıyoruz.
// MobileWiFi özel çerçevesi; başlık yok, imzalar elle bildirildi.
typedef void *WiFiManagerRef;
typedef void *WiFiDeviceClientRef;
typedef void *WiFiNetworkRef;
typedef void (*TaramaBitti)(WiFiDeviceClientRef aygit, CFArrayRef aglar, int hata, void *baglam);
typedef void (*KatilmaBitti)(WiFiDeviceClientRef aygit, WiFiNetworkRef ag, CFDictionaryRef bilgi, int hata, void *baglam);

extern WiFiManagerRef WiFiManagerClientCreate(CFAllocatorRef ayirici, int tur);
extern void WiFiManagerClientScheduleWithRunLoop(WiFiManagerRef yonetici, CFRunLoopRef dongu, CFStringRef kip);
extern CFArrayRef WiFiManagerClientCopyDevices(WiFiManagerRef yonetici);
extern CFArrayRef WiFiManagerClientCopyNetworks(WiFiManagerRef yonetici);
extern WiFiNetworkRef WiFiDeviceClientCopyCurrentNetwork(WiFiDeviceClientRef aygit);
extern int WiFiDeviceClientScanAsync(WiFiDeviceClientRef aygit, CFDictionaryRef secenek, TaramaBitti geri, void *baglam);
extern int WiFiDeviceClientAssociateAsync(WiFiDeviceClientRef aygit, WiFiNetworkRef ag, KatilmaBitti geri, void *baglam);
extern CFStringRef WiFiNetworkGetSSID(WiFiNetworkRef ag);

// Erişim noktasının adı "areis iPhone’u"; büyük/küçük harf, boşluk ve kesme işareti
// karşılaştırmaya girmez.
static NSString *const kHotspotAdi = @"areisiphoneu";

static WiFiManagerRef wifiYonetici;
static WiFiDeviceClientRef wifiAygit;
static BOOL katiliyor; // tarama ya da katılma sürerken yenisi başlamaz
// iPad 2'de Bluetooth ile Wi-Fi aynı yongada. 31 Eki: erişim noktası açıkken Bluetooth her
// 15 sn'de iPhone'a ve hoparlöre bağlanmaya uğraşırken katılma -3906 ve 5 ile düştü.
// Erişim noktası görülünce Bluetooth bir süre susar, telsiz katılmaya kalır.
static time_t btSusmaBitisi;
static const int kBTSusma = 60; // sn
static time_t islemBasi;
static time_t sonrakiDeneme; // başarısız katılmadan sonra beklenir
static const int kKatilmaBekleme = 20; // sn; erişim noktası kısa süre görünür, uzun bekleme onu kaçırıyor

static BOOL hotspotAdiMi(WiFiNetworkRef ag) {
    CFStringRef ssid = ag ? WiFiNetworkGetSSID(ag) : NULL;
    if (!ssid) return NO;
    NSMutableString *sade = [NSMutableString string];
    NSString *ad = [(__bridge NSString *)ssid lowercaseString];
    for (NSUInteger i = 0; i < ad.length; i++) {
        unichar c = [ad characterAtIndex:i];
        if ([[NSCharacterSet alphanumericCharacterSet] characterIsMember:c]) [sade appendFormat:@"%C", c];
    }
    return [sade isEqualToString:kHotspotAdi];
}

static void katilmaBitti(WiFiDeviceClientRef aygit, WiFiNetworkRef ag, CFDictionaryRef bilgi, int hata, void *baglam) {
    NSLog(@"aracbaslat hotspot'a katılma sonucu: %d", hata);
    katiliyor = NO;
    // Hotspot görünüp katılma -100 ile düşünce 10 sn'de bir tara-katıl döngüsü iPad'i donduruyordu.
    if (hata != 0) sonrakiDeneme = time(NULL) + kKatilmaBekleme;
}

static void taramaBitti(WiFiDeviceClientRef aygit, CFArrayRef aglar, int hata, void *baglam) {
    WiFiNetworkRef bulunan = NULL;
    for (CFIndex i = 0; aglar && i < CFArrayGetCount(aglar); i++) {
        WiFiNetworkRef ag = (WiFiNetworkRef)CFArrayGetValueAtIndex(aglar, i);
        if (hotspotAdiMi(ag)) { bulunan = ag; break; }
    }
    if (!bulunan) {
        katiliyor = NO;
        return;
    }
    // Taramadan gelen ağda parola yok (31 Eki: katılma -3906). Aynı adlı kayıtlı ağ
    // parolayı taşıyor; onunla katılınır.
    CFStringRef ssid = WiFiNetworkGetSSID(bulunan);
    CFArrayRef kayitli = WiFiManagerClientCopyNetworks(wifiYonetici);
    BOOL kayitliMi = NO;
    for (CFIndex i = 0; ssid && kayitli && i < CFArrayGetCount(kayitli); i++) {
        WiFiNetworkRef ag = (WiFiNetworkRef)CFArrayGetValueAtIndex(kayitli, i);
        CFStringRef kssid = WiFiNetworkGetSSID(ag);
        if (kssid && CFStringCompare(kssid, ssid, 0) == kCFCompareEqualTo) { bulunan = ag; kayitliMi = YES; break; }
    }
    btSusmaBitisi = time(NULL) + kBTSusma;
    NSLog(@"aracbaslat hotspot görüldü, katılınıyor (%@)", kayitliMi ? @"kayıtlı ağ" : @"tarama kaydı");
    int sonuc = WiFiDeviceClientAssociateAsync(aygit, bulunan, katilmaBitti, NULL);
    if (kayitli) CFRelease(kayitli);
    if (sonuc != 0) {
        NSLog(@"aracbaslat katılma başlatılamadı: %d", sonuc);
        katiliyor = NO;
    }
}

static void taniTaramasi(WiFiDeviceClientRef aygit, CFArrayRef aglar, int hata, void *baglam) {
    printf("tarama hata=%d, %ld ağ\n", hata, aglar ? (long)CFArrayGetCount(aglar) : 0L);
    for (CFIndex i = 0; aglar && i < CFArrayGetCount(aglar); i++) {
        WiFiNetworkRef ag = (WiFiNetworkRef)CFArrayGetValueAtIndex(aglar, i);
        CFStringRef ssid = WiFiNetworkGetSSID(ag);
        printf("%s %s\n", hotspotAdiMi(ag) ? "*" : " ", ssid ? [(__bridge NSString *)ssid UTF8String] : "?");
    }
    CFArrayRef kayitli = WiFiManagerClientCopyNetworks(wifiYonetici);
    for (CFIndex i = 0; kayitli && i < CFArrayGetCount(kayitli); i++) {
        WiFiNetworkRef ag = (WiFiNetworkRef)CFArrayGetValueAtIndex(kayitli, i);
        CFStringRef kssid = WiFiNetworkGetSSID(ag);
        printf("kayıtlı %s %s\n", hotspotAdiMi(ag) ? "*" : " ", kssid ? [(__bridge NSString *)kssid UTF8String] : "?");
    }
    if (kayitli) CFRelease(kayitli);
    WiFiNetworkRef simdiki = WiFiDeviceClientCopyCurrentNetwork(aygit);
    CFStringRef ssid = simdiki ? WiFiNetworkGetSSID(simdiki) : NULL;
    printf("şu an bağlı: %s\n", ssid ? [(__bridge NSString *)ssid UTF8String] : "yok");
    if (simdiki) CFRelease(simdiki);
    fflush(stdout);
    CFRunLoopStop(CFRunLoopGetCurrent());
}

static void wifiHazirla(void) {
    wifiYonetici = WiFiManagerClientCreate(kCFAllocatorDefault, 0);
    if (!wifiYonetici) {
        NSLog(@"aracbaslat Wi-Fi yöneticisi açılamadı");
        return;
    }
    WiFiManagerClientScheduleWithRunLoop(wifiYonetici, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    CFArrayRef aygitlar = WiFiManagerClientCopyDevices(wifiYonetici);
    if (aygitlar && CFArrayGetCount(aygitlar) > 0) {
        wifiAygit = (WiFiDeviceClientRef)CFRetain(CFArrayGetValueAtIndex(aygitlar, 0));
    } else {
        NSLog(@"aracbaslat Wi-Fi aygıtı bulunamadı");
    }
    if (aygitlar) CFRelease(aygitlar);
}

// Wi-Fi hiçbir ağa bağlı değilse (evdeki ağa dokunmaz) erişim noktasını arar.
static void hotspotaKatil(void) {
    if (!wifiAygit) return;
    if (time(NULL) < sonrakiDeneme) return;
    if (katiliyor) {
        if (time(NULL) - islemBasi < 30) return;
        NSLog(@"aracbaslat tarama/katılma yanıt vermedi, yeniden deneniyor");
    }
    WiFiNetworkRef simdiki = WiFiDeviceClientCopyCurrentNetwork(wifiAygit);
    if (simdiki) {
        CFRelease(simdiki);
        return;
    }
    katiliyor = YES;
    islemBasi = time(NULL);
    int sonuc = WiFiDeviceClientScanAsync(wifiAygit, (__bridge CFDictionaryRef)@{}, taramaBitti, NULL);
    if (sonuc != 0) katiliyor = NO; // Wi-Fi kapalıyken tarama reddedilir; sessizce bekle
}

static BOOL hotspottaMi(void) {
    struct ifaddrs *arayuzler = NULL;
    if (getifaddrs(&arayuzler) != 0) return NO;

    BOOL hotspotta = NO;
    for (struct ifaddrs *arayuz = arayuzler; arayuz; arayuz = arayuz->ifa_next) {
        if (!arayuz->ifa_addr || ![@(arayuz->ifa_name) isEqualToString:@"en0"] ||
            arayuz->ifa_addr->sa_family != AF_INET) continue;
        char adres[INET_ADDRSTRLEN];
        struct sockaddr_in *ipv4 = (struct sockaddr_in *)arayuz->ifa_addr;
        if (inet_ntop(AF_INET, &ipv4->sin_addr, adres, sizeof(adres)) &&
            [@(adres) hasPrefix:@"172.20.10."]) {
            hotspotta = YES;
            break;
        }
    }
    freeifaddrs(arayuzler);
    return hotspotta;
}

#pragma mark - Bluetooth aygıtlarına kendiliğinden bağlanma

// iOS 9 eşleşmiş hoparlöre kendisi bağlanmıyor (bağlantıyı hoparlör başlatmazsa).
// iPhone'a da aynı yolla bağlanılıyor: iPhone'daki Kestirmeler "iPad bağlanınca" tetikleyicisiyle
// erişim noktasını açıyor. Ev Wi-Fi'ı arabaya kadar yettiği için "ağdan ayrılınca" tetiklenmiyordu.
// Hotspot'a katılınca Bluetooth susturulur: iPhone bağlantısı kesilir, menzilde olmayan aygıt
// aranmaz. iPad 2'de Bluetooth ile Wi-Fi aynı yongada; 15 sn'de bir arama ve açık iPhone bağlantısı
// yansıtmanın Wi-Fi'ını kesintiye uğratıyordu (30 Eki arabada donma).
// BluetoothManager özel çerçevesi; sınıflar çalışma anında alınır, başlık yok.
@protocol BTYonetici
+ (id)sharedInstance;
- (BOOL)available;
- (BOOL)powered;
- (NSArray *)pairedDevices;
@end

@protocol BTAygit
- (NSString *)name;
- (NSString *)address;
- (BOOL)connected;
- (void)connect;
- (void)disconnect;
@end

// Adında bunlardan biri geçen eşleşmiş aygıtlar aranır (büyük/küçük harf önemsiz).
static NSArray<NSString *> *btAdlari(void) { return @[@"thinkplus", @"iphone"]; }
static const int kBTDenemeAraligi = 15; // sn; menzilde değilken telsizi meşgul etmesin

static id<BTYonetici> btYonetici;
static NSMutableDictionary<NSString *, NSNumber *> *btSonDeneme; // ad -> son deneme zamanı

static void btHazirla(void) {
    dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager", RTLD_LAZY);
    Class sinif = NSClassFromString(@"BluetoothManager");
    if (!sinif) {
        NSLog(@"aracbaslat BluetoothManager yüklenemedi");
        return;
    }
    btYonetici = [(Class<BTYonetici>)sinif sharedInstance];
}

static NSString *btAdi(id<BTAygit> aygit) {
    for (NSString *ad in btAdlari()) {
        if ([[aygit name] rangeOfString:ad options:NSCaseInsensitiveSearch].location != NSNotFound) return ad;
    }
    return nil;
}

static void aygitlaraBaglan(BOOL hotspotta) {
    if (!btYonetici || ![btYonetici available] || ![btYonetici powered]) return;
    if (!hotspotta && (katiliyor || time(NULL) < btSusmaBitisi)) return;
    if (!btSonDeneme) btSonDeneme = [NSMutableDictionary dictionary];
    for (id<BTAygit> aygit in [btYonetici pairedDevices]) {
        NSString *ad = btAdi(aygit);
        if (!ad) continue;
        if (hotspotta) {
            // iPhone bağlantısının tek işi erişim noktasını açtırmaktı; hoparlör bağlıysa kalır.
            if ([ad isEqualToString:@"iphone"] && [aygit connected]) {
                NSLog(@"aracbaslat hotspot'tayız, iPhone Bluetooth bağlantısı kesiliyor");
                [aygit disconnect];
            }
            continue;
        }
        if ([aygit connected]) continue;
        if (time(NULL) - [btSonDeneme[ad] longValue] < kBTDenemeAraligi) continue;
        btSonDeneme[ad] = @(time(NULL));
        [aygit connect];
    }
}

#pragma mark - Takılan medya servisi

// 31 Eki: mediaserverd takılınca Araç görüntü katmanını kurarken onu bekliyor, iOS da
// "failed to scene-create" ile 20 sn'de öldürüp yeniden açıyordu; respring çözmedi.
// Bu kayıt görülünce servis öldürülür, launchd onu temiz başlatır.
static NSString *const kCokmeDizini = @"/var/mobile/Library/Logs/CrashReporter";
static time_t sonCokmeTaramasi;
static time_t sonMedyaOldurme;
static const int kCokmeTaramaAraligi = 10; // sn
static const int kMedyaOldurmeBekleme = 300; // sn; düzelmezse döngüye girmesin

static pid_t surecBul(const char *ad) {
    int mib[3] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL};
    size_t boyut = 0;
    if (sysctl(mib, 3, NULL, &boyut, NULL, 0) != 0) return 0;
    struct kinfo_proc *liste = malloc(boyut);
    if (!liste) return 0;
    pid_t bulunan = 0;
    if (sysctl(mib, 3, liste, &boyut, NULL, 0) == 0) {
        for (size_t i = 0; i < boyut / sizeof(struct kinfo_proc); i++) {
            if ([@(liste[i].kp_proc.p_comm) isEqualToString:@(ad)]) { bulunan = liste[i].kp_proc.p_pid; break; }
        }
    }
    free(liste);
    return bulunan;
}

// Yeni bir scene-create kaydında mediaserverd'yi öldürür; öldürdüyse YES döner.
static BOOL medyaServisiniDenetle(void) {
    time_t simdi = time(NULL);
    if (simdi - sonCokmeTaramasi < kCokmeTaramaAraligi) return NO;
    time_t oncekiTarama = sonCokmeTaramasi;
    sonCokmeTaramasi = simdi;
    if (simdi - sonMedyaOldurme < kMedyaOldurmeBekleme) return NO;

    BOOL takildi = NO;
    NSFileManager *dosyalar = [NSFileManager defaultManager];
    for (NSString *ad in [dosyalar contentsOfDirectoryAtPath:kCokmeDizini error:NULL]) {
        if (![ad hasPrefix:@"stacks+Arac-"]) continue;
        NSString *yol = [kCokmeDizini stringByAppendingPathComponent:ad];
        NSDate *degisme = [dosyalar attributesOfItemAtPath:yol error:NULL].fileModificationDate;
        if ([degisme timeIntervalSince1970] < oncekiTarama) continue;
        NSString *icerik = [NSString stringWithContentsOfFile:yol encoding:NSUTF8StringEncoding error:NULL];
        if ([icerik rangeOfString:@"failed to scene-create"].location != NSNotFound) { takildi = YES; break; }
    }
    if (!takildi) return NO;

    pid_t medya = surecBul("mediaserverd");
    int sonuc = medya ? kill(medya, SIGKILL) : -1;
    sonMedyaOldurme = simdi;
    NSLog(@"aracbaslat Araç scene-create ile düştü, mediaserverd (%d) öldürüldü: %d", medya, sonuc);
    return sonuc == 0;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        void *kitaplik = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
        UygulamaAc uygulamaAc = kitaplik ? (UygulamaAc)dlsym(kitaplik, "SBSLaunchApplicationWithIdentifier") : NULL;
        if (!uygulamaAc) NSLog(@"aracbaslat açma API'si yüklenemedi: %s", dlerror());
        // Ekran kararmışken düz açma Araç'ı arka planda bırakıyor; kilidi açma seçeneği öne getirir.
        SecenekliAc secenekliAc = kitaplik ? (SecenekliAc)dlsym(kitaplik, "SBSLaunchApplicationWithIdentifierAndURLAndLaunchOptions") : NULL;
        NSDictionary *acmaSecenegi = @{@"__UnlockDevice": @YES, @"__ActivateSuspended": @NO};

        wifiHazirla();
        btHazirla();
        if (argc == 1) uykuyuEngelle();

        // Tanı: "aracbaslat bt" eşleşmiş Bluetooth aygıtlarını yazar ve çıkar.
        if (argc > 1 && [@(argv[1]) isEqualToString:@"bt"]) {
            // Yönetici hazır olana dek bildirimleri işlemesi gerekiyor.
            for (int i = 0; i < 10 && !(btYonetici && [btYonetici available]); i++)
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false);
            printf("bt hazir=%d acik=%d\n", (int)[btYonetici available], (int)[btYonetici powered]);
            for (id<BTAygit> aygit in [btYonetici pairedDevices])
                printf("%s %s %s bagli=%d\n", btAdi(aygit) ? "*" : " ",
                       [[aygit name] UTF8String], [[aygit address] UTF8String], (int)[aygit connected]);
            return 0;
        }

        // Tanı: "aracbaslat tara" görünen ağları yazar, hotspot'u işaretler ve çıkar.
        if (argc > 1 && [@(argv[1]) isEqualToString:@"tara"]) {
            if (!wifiAygit) return 1;
            WiFiDeviceClientScanAsync(wifiAygit, (__bridge CFDictionaryRef)@{}, taniTaramasi, NULL);
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 20, false);
            return 0;
        }

        sonCokmeTaramasi = time(NULL); // açılıştan önceki eski kayıtlara bakılmaz
        BOOL onceHotspotta = NO;
        int kalanDeneme = 0;
        while (YES) {
            @autoreleasepool {
                BOOL hotspotta = hotspottaMi();
                if (hotspotta != onceHotspotta) {
                    NSLog(@"aracbaslat hotspot %@", hotspotta ? @"bağlandı" : @"ayrıldı");
                    // İlk deneme ve başarısızsa sonraki turlarda 10 ek deneme.
                    kalanDeneme = hotspotta ? 11 : 0;
                }
                // Servis yeniden kalkınca Araç'ı bir kez daha öne getir.
                if (medyaServisiniDenetle() && hotspotta) kalanDeneme = 3;
                if (hotspotta && kalanDeneme > 0) {
                    int sonuc = secenekliAc ? secenekliAc(CFSTR("tr.niladsp.arac"), NULL, NULL, (__bridge CFDictionaryRef)acmaSecenegi, false)
                              : uygulamaAc ? uygulamaAc(CFSTR("tr.niladsp.arac"), false) : -1;
                    kalanDeneme--;
                    NSLog(@"aracbaslat açma sonucu: %d, kalan deneme: %d", sonuc, kalanDeneme);
                    if (sonuc == 0) kalanDeneme = 0;
                    else if (kalanDeneme == 0) NSLog(@"aracbaslat deneme sınırına ulaşıldı");
                }
                onceHotspotta = hotspotta;
                if (!hotspotta) hotspotaKatil();
                aygitlaraBaglan(hotspotta);
            }
            // Tarama ve katılma geri çağrıları bu döngüde gelir.
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 3, false);
        }
    }
}
