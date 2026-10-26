#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <ifaddrs.h>
#import <netinet/in.h>
#import <stdbool.h>
#import <unistd.h>

typedef int (*UygulamaAc)(CFStringRef identifier, Boolean suspended);

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
static time_t islemBasi;

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
    NSLog(@"aracbaslat hotspot görüldü, katılınıyor");
    int sonuc = WiFiDeviceClientAssociateAsync(aygit, bulunan, katilmaBitti, NULL);
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

#pragma mark - Bluetooth hoparlöre kendiliğinden bağlanma

// iOS 9 eşleşmiş hoparlöre kendisi bağlanmıyor (bağlantıyı hoparlör başlatmazsa).
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
@end

// Adında bu geçen eşleşmiş aygıt aranır (büyük/küçük harf önemsiz).
static NSString *const kHoparlorAdi = @"thinkplus";
static const int kBTDenemeAraligi = 15; // sn; menzilde değilken telsizi meşgul etmesin

static id<BTYonetici> btYonetici;
static time_t btSonDeneme;

static void btHazirla(void) {
    dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager", RTLD_LAZY);
    Class sinif = NSClassFromString(@"BluetoothManager");
    if (!sinif) {
        NSLog(@"aracbaslat BluetoothManager yüklenemedi");
        return;
    }
    btYonetici = [(Class<BTYonetici>)sinif sharedInstance];
}

static id<BTAygit> hoparlor(void) {
    for (id<BTAygit> aygit in [btYonetici pairedDevices]) {
        if ([[aygit name] rangeOfString:kHoparlorAdi options:NSCaseInsensitiveSearch].location != NSNotFound) return aygit;
    }
    return nil;
}

static void hoparloreBaglan(void) {
    if (!btYonetici || ![btYonetici available] || ![btYonetici powered]) return;
    if (time(NULL) - btSonDeneme < kBTDenemeAraligi) return;
    id<BTAygit> aygit = hoparlor();
    if (!aygit || [aygit connected]) return;
    btSonDeneme = time(NULL);
    [aygit connect];
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        void *kitaplik = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
        UygulamaAc uygulamaAc = kitaplik ? (UygulamaAc)dlsym(kitaplik, "SBSLaunchApplicationWithIdentifier") : NULL;
        if (!uygulamaAc) NSLog(@"aracbaslat açma API'si yüklenemedi: %s", dlerror());

        wifiHazirla();
        btHazirla();

        // Tanı: "aracbaslat bt" eşleşmiş Bluetooth aygıtlarını yazar ve çıkar.
        if (argc > 1 && [@(argv[1]) isEqualToString:@"bt"]) {
            // Yönetici hazır olana dek bildirimleri işlemesi gerekiyor.
            for (int i = 0; i < 10 && !(btYonetici && [btYonetici available]); i++)
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false);
            printf("bt hazir=%d acik=%d\n", (int)[btYonetici available], (int)[btYonetici powered]);
            for (id<BTAygit> aygit in [btYonetici pairedDevices])
                printf("%s %s %s bagli=%d\n", [[aygit name] rangeOfString:kHoparlorAdi options:NSCaseInsensitiveSearch].location != NSNotFound ? "*" : " ",
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
                if (hotspotta && kalanDeneme > 0) {
                    int sonuc = uygulamaAc ? uygulamaAc(CFSTR("tr.niladsp.arac"), false) : -1;
                    kalanDeneme--;
                    NSLog(@"aracbaslat açma sonucu: %d, kalan deneme: %d", sonuc, kalanDeneme);
                    if (sonuc == 0) kalanDeneme = 0;
                    else if (kalanDeneme == 0) NSLog(@"aracbaslat deneme sınırına ulaşıldı");
                }
                onceHotspotta = hotspotta;
                if (!hotspotta) hotspotaKatil();
                hoparloreBaglan();
            }
            // Tarama ve katılma geri çağrıları bu döngüde gelir.
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 3, false);
        }
    }
}
