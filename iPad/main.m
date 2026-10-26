//
//  main.m
//  Arac
//
//  iPhone yayın eklentisinden (TCP 8889) H.264 + PCM alıp gösteren iPad istemcisi.
//  iOS 9.3.5 / armv7 hedefi; yalnızca iOS 9 SDK API'leri kullanılır.
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>

#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <pthread.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>

// Bu SDK'nın .tbd dosyalarında memcpy/memset dışa aktarımı yok. Kendi sürümlerimizi
// veriyoruz; volatile, derleyicinin döngüyü yeniden memcpy çağrısına çevirmesini önler.
#undef memcpy
#undef memset
void *memcpy(void *hedef, const void *kaynak, size_t uzunluk) {
    volatile unsigned char *d = (volatile unsigned char *)hedef;
    const volatile unsigned char *s = (const volatile unsigned char *)kaynak;
    while (uzunluk--) *d++ = *s++;
    return hedef;
}

void *memset(void *hedef, int deger, size_t uzunluk) {
    volatile unsigned char *d = (volatile unsigned char *)hedef;
    while (uzunluk--) *d++ = (unsigned char)deger;
    return hedef;
}

// Sunucu bilgileri
static NSString *const kDurumBekliyor = @"iPhone bekleniyor (ReplayKit 8889 / AirPlay Ekran Yansıtma)";
static const uint32_t kAzamiYuk = 4u * 1024u * 1024u;

#pragma mark - Küçük yardımcılar

static uint16_t oku16be(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[0] << 8) | p[1]);
}

static uint32_t oku32be(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

// Zaman aşımı (SO_RCVTIMEO) devreye girerse NO döner.
static BOOL tumunuOku(int fd, void *tampon, size_t uzunluk) {
    uint8_t *p = (uint8_t *)tampon;
    size_t alinan = 0;
    while (alinan < uzunluk) {
        ssize_t n = recv(fd, p + alinan, uzunluk - alinan, 0);
        if (n > 0) {
            alinan += (size_t)n;
            continue;
        }
        if (n == 0) return NO;
        if (errno == EINTR) continue;
        return NO; // EAGAIN/EWOULDBLOCK = 5 sn zaman aşımı ya da gerçek hata
    }
    return YES;
}

// Bloklamayan connect + select ile zaman aşımı; başarıda bloklayan soket döner.
static int sunucuyaBaglan(const char *host, int port, int saniye) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
        close(fd);
        return -1;
    }

    int eski = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, eski | O_NONBLOCK);

    int r = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (r < 0 && errno != EINPROGRESS) {
        close(fd);
        return -1;
    }
    if (r < 0) {
        fd_set yaz;
        FD_ZERO(&yaz);
        FD_SET(fd, &yaz);
        struct timeval tv;
        tv.tv_sec = saniye;
        tv.tv_usec = 0;
        r = select(fd + 1, NULL, &yaz, NULL, &tv);
        if (r <= 0) {
            close(fd);
            return -1;
        }
        int hata = 0;
        socklen_t hataBoyu = sizeof(hata);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &hata, &hataBoyu) != 0 || hata != 0) {
            close(fd);
            return -1;
        }
    }

    fcntl(fd, F_SETFL, eski); // yeniden bloklayan mod

    int bir = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &bir, sizeof(bir));
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &bir, sizeof(bir));
    struct timeval okuma;
    okuma.tv_sec = 5;
    okuma.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &okuma, sizeof(okuma));
    return fd;
}

#pragma mark - Ses halka tamponu

typedef struct {
    int16_t *veri;
    size_t kapasiteKare; // yaklaşık 2 saniye
    size_t kanal;
    size_t bas;
    size_t adet;
} PCMHalka;

#pragma mark - Etkin kaynak

// İki kaynak aynı katmana yazdığı için son 'V' alan kaynağı işaretler.
@interface EtkinKaynak : NSObject
+ (instancetype)paylasilan;
- (BOOL)etkinMi:(NSString *)ad;
- (BOOL)etkinYap:(NSString *)ad;
@end

@implementation EtkinKaynak {
    NSString *_ad;
}

+ (instancetype)paylasilan {
    static EtkinKaynak *paylasilan = nil;
    static dispatch_once_t bir;
    dispatch_once(&bir, ^{ paylasilan = [[EtkinKaynak alloc] init]; });
    return paylasilan;
}

- (BOOL)etkinMi:(NSString *)ad {
    @synchronized (self) {
        return _ad != nil && [_ad isEqualToString:ad];
    }
}

// Kaynak değiştiyse YES döner.
- (BOOL)etkinYap:(NSString *)ad {
    @synchronized (self) {
        if (_ad != nil && [_ad isEqualToString:ad]) return NO;
        _ad = [ad copy];
        return YES;
    }
}

@end

#pragma mark - Alıcı

@class Alici;

@interface Alici : NSObject
@property (nonatomic, strong) AVSampleBufferDisplayLayer *goruntuKatmani;
@property (nonatomic, copy, readonly) NSString *ad;
- (instancetype)initWithKatman:(AVSampleBufferDisplayLayer *)katman
                          host:(const char *)host
                          port:(int)port
                            ad:(NSString *)ad;
- (void)baslat;
- (void)durdur;
- (BOOL)bagliMi;
- (void)setBekliyor:(BOOL)bekliyor;
- (BOOL)bekliyorMu;
- (int32_t)kareSayaciniSifirla;
- (int32_t)sesSayaciniSifirla;
- (NSString *)sesDurumu;
- (void)sesTamponuDoldur:(AudioQueueBufferRef)tampon;
@end

// AudioQueue geri çağırması; halka tampondan okur, boşsa sessizlik yazar.
static void SesGeriCagirma(void *kullanici, AudioQueueRef kuyruk, AudioQueueBufferRef tampon) {
    Alici *alici = (__bridge Alici *)kullanici;
    [alici sesTamponuDoldur:tampon];
    AudioQueueEnqueueBuffer(kuyruk, tampon, 0, NULL);
}

@implementation Alici {
    BOOL _calisiyor;
    BOOL _bagli;
    BOOL _bekliyor; // anahtar kare bekleniyor
    int _soket;
    char *_host;
    int _port;
    EtkinKaynak *_secici;
    BOOL _anahtarSeyrek;

    CMVideoFormatDescriptionRef _bicim;
    NSData *_sps;
    NSData *_pps;

    AudioQueueRef _sesKuyrugu;
    double _sesHizi;
    int _sesKanali;
    PCMHalka _halka;
    pthread_mutex_t _halkaKilit;

    volatile int32_t _kareSayaci;
    volatile int32_t _sesSayaci; // tanı: saniyedeki ses paketi
}

- (instancetype)initWithKatman:(AVSampleBufferDisplayLayer *)katman
                          host:(const char *)host
                          port:(int)port
                            ad:(NSString *)ad {
    self = [super init];
    if (self) {
        _goruntuKatmani = katman;
        _soket = -1;
        _bekliyor = YES;
        _calisiyor = NO;
        _host = strdup(host);
        _port = port;
        _ad = [ad copy];
        _secici = [EtkinKaynak paylasilan];
        _anahtarSeyrek = [ad isEqualToString:@"AirPlay"];
        memset(&_halka, 0, sizeof(_halka));
        pthread_mutex_init(&_halkaKilit, NULL);
    }
    return self;
}

- (void)dealloc {
    [self durdur];
    free(_host);
    if (_sesKuyrugu) {
        AudioQueueStop(_sesKuyrugu, true);
        AudioQueueDispose(_sesKuyrugu, true);
        _sesKuyrugu = NULL;
    }
    if (_bicim) CFRelease(_bicim);
    pthread_mutex_lock(&_halkaKilit);
    free(_halka.veri);
    _halka.veri = NULL;
    pthread_mutex_unlock(&_halkaKilit);
    pthread_mutex_destroy(&_halkaKilit);
}

- (void)baslat {
    if (_calisiyor) return;
    _calisiyor = YES;
    [NSThread detachNewThreadSelector:@selector(agDongusu) toTarget:self withObject:nil];
}

- (void)durdur {
    _calisiyor = NO;
    // Soket ayrı iş parçacığında; uygulama ömrü boyunca çalıştığı için burada kapatmıyoruz.
}

- (BOOL)bagliMi {
    BOOL c;
    @synchronized (self) { c = _bagli; }
    return c;
}

- (void)setBagli:(BOOL)bagli {
    @synchronized (self) { _bagli = bagli; }
}

- (void)setBekliyor:(BOOL)bekliyor {
    @synchronized (self) { _bekliyor = bekliyor; }
}

- (BOOL)bekliyorMu {
    BOOL b;
    @synchronized (self) { b = _bekliyor; }
    return b;
}

- (int32_t)kareSayaciniSifirla {
    return __sync_lock_test_and_set(&_kareSayaci, 0);
}

- (int32_t)sesSayaciniSifirla {
    return __sync_lock_test_and_set(&_sesSayaci, 0);
}

- (NSString *)sesDurumu {
    return [NSString stringWithFormat:@"%.0f Hz/%d kanal, kuyruk %@", _sesHizi, _sesKanali, _sesKuyrugu ? @"var" : @"yok"];
}

// Anahtar kare ise beklemeyi bitir; beklerken gelen anahtar olmayan kareyi at.
- (BOOL)buKareIslenebilir:(BOOL)anahtar {
    @synchronized (self) {
        if (_bekliyor) {
            if (!anahtar) return NO;
            _bekliyor = NO;
        }
        return YES;
    }
}

#pragma mark Ağ

- (void)agDongusu {
    while (_calisiyor) {
        @autoreleasepool {
            int fd = sunucuyaBaglan(_host, _port, 2);
            if (fd < 0) {
                [self setBagli:NO];
                [NSThread sleepForTimeInterval:1.0];
                continue;
            }
            _soket = fd;
            [self setBagli:YES];
            [self okumaDongusu:fd];
            close(fd);
            _soket = -1;
            [self setBagli:NO];
            [self setBekliyor:YES]; // yeniden bağlanınca anahtar kare bekle
            [self sesTamponunuTemizle];
        }
    }
}

- (void)okumaDongusu:(int)fd {
    while (_calisiyor) {
        uint8_t baslik[5];
        if (!tumunuOku(fd, baslik, sizeof(baslik))) return;

        uint32_t uzunluk = oku32be(baslik + 1);
        if (uzunluk > kAzamiYuk) return; // anormal paket: bağlantıyı kes

        uint8_t *yuk = NULL;
        if (uzunluk > 0) {
            yuk = (uint8_t *)malloc(uzunluk);
            if (!yuk) return;
            if (!tumunuOku(fd, yuk, uzunluk)) {
                free(yuk);
                return;
            }
        }

        @autoreleasepool {
            switch (baslik[0]) {
                case 'V':
                    [self parametreSetleri:yuk uzunluk:uzunluk];
                    break;
                case 'F':
                    [self videoKaresi:yuk uzunluk:uzunluk];
                    break;
                case 'A':
                    [self sesPaketi:yuk uzunluk:uzunluk];
                    break;
                default:
                    break;
            }
        }
        free(yuk);
    }
}

#pragma mark Video

- (void)parametreSetleri:(const uint8_t *)p uzunluk:(size_t)n {
    if (!p || n < 4) return;
    size_t pos = 0;
    uint16_t spsBoyu = oku16be(p + pos);
    pos += 2;
    if (spsBoyu == 0 || pos + spsBoyu + 2 > n) return;
    NSData *sps = [NSData dataWithBytes:(p + pos) length:spsBoyu];
    pos += spsBoyu;

    uint16_t ppsBoyu = oku16be(p + pos);
    pos += 2;
    if (ppsBoyu == 0 || pos + ppsBoyu > n) return;
    NSData *pps = [NSData dataWithBytes:(p + pos) length:ppsBoyu];

    // SPS/PPS değişmediyse biçim tanımını yeniden kurma. Son 'V' alan kaynak
    // yine de katmanın sahibi olur.
    BOOL ayniParametreler = NO;
    @synchronized (self) {
        ayniParametreler = (_sps && _pps && [_sps isEqualToData:sps] && [_pps isEqualToData:pps]);
    }
    if (ayniParametreler) {
        if ([_secici etkinYap:_ad]) {
            [self setBekliyor:YES]; // yeni kaynak: anahtar kare bekle
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.goruntuKatmani flush];
            });
        }
        return;
    }

    const uint8_t *isaretciler[2] = { (const uint8_t *)sps.bytes, (const uint8_t *)pps.bytes };
    size_t boyutlar[2] = { sps.length, pps.length };
    CMVideoFormatDescriptionRef yeni = NULL;
    OSStatus durum = CMVideoFormatDescriptionCreateFromH264ParameterSets(
        kCFAllocatorDefault, 2, isaretciler, boyutlar, 4, &yeni);
    if (durum != noErr || !yeni) return;

    [_secici etkinYap:_ad];

    @synchronized (self) {
        if (_bicim) CFRelease(_bicim);
        _bicim = yeni;
        _sps = sps;
        _pps = pps;
        _bekliyor = YES; // yeni biçimden sonra anahtar kare bekle
    }

    // Eski kareleri/çözücüyü bırak; ana kuyrukta sıralı olsun.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.goruntuKatmani flush];
    });
}

- (CMVideoFormatDescriptionRef)kopyaBicim {
    @synchronized (self) {
        if (_bicim) return (CMVideoFormatDescriptionRef)CFRetain(_bicim);
        return NULL;
    }
}

- (void)videoKaresi:(const uint8_t *)p uzunluk:(size_t)n {
    if (!p || n < 2) return;
    BOOL anahtar = (p[0] != 0);
    if (![self buKareIslenebilir:anahtar]) return;

    __sync_add_and_fetch(&_kareSayaci, 1);

    // Katmanın sahibi son 'V' alan kaynaktır; öbür kaynağın kareleri kuyruğa girmez.
    if (![_secici etkinMi:_ad]) return;

    CMVideoFormatDescriptionRef bicim = [self kopyaBicim];
    if (!bicim) return;

    size_t veriBoyu = n - 1;
    CMBlockBufferRef blok = NULL;
    OSStatus durum = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault, NULL, veriBoyu, kCFAllocatorDefault, NULL,
        0, veriBoyu, kCMBlockBufferAssureMemoryNowFlag, &blok);
    if (durum != noErr || !blok) {
        CFRelease(bicim);
        return;
    }
    durum = CMBlockBufferReplaceDataBytes(p + 1, blok, 0, veriBoyu);
    if (durum != noErr) {
        CFRelease(blok);
        CFRelease(bicim);
        return;
    }

    CMSampleBufferRef ornek = NULL;
    size_t ornekBoyu = veriBoyu;
    durum = CMSampleBufferCreate(kCFAllocatorDefault, blok, true, NULL, NULL,
                                 bicim, 1, 0, NULL, 1, &ornekBoyu, &ornek);
    CFRelease(blok);
    CFRelease(bicim);
    if (durum != noErr || !ornek) return;

    // DisplayImmediately örnek başına ek dizisine yazılmalı; tamponun kendisine
    // yazılırsa katman zamanlama bekler.
    CFArrayRef ekler = CMSampleBufferGetSampleAttachmentsArray(ornek, true);
    if (ekler && CFArrayGetCount(ekler) > 0) {
        CFMutableDictionaryRef ek = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(ekler, 0);
        CFDictionarySetValue(ek, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    }

    id tasinan = CFBridgingRelease(ornek); // ARC bloğa taşısın
    dispatch_async(dispatch_get_main_queue(), ^{
        AVSampleBufferDisplayLayer *katman = self.goruntuKatmani;
        if (katman.status == AVQueuedSampleBufferRenderingStatusFailed) {
            [katman flush];
            if (!anahtar) {
                [self setBekliyor:YES]; // sonraki anahtar kareye kadar atla
                // AirPlay'de sıradaki anahtar kare dakikalarca gelmeyebilir; bağlantıyı
                // kesince daemon yeniden bağlanışta son IDR'den itibaren kareleri yollar.
                int fd = _soket;
                if (_anahtarSeyrek && fd >= 0) shutdown(fd, SHUT_RDWR);
                return;
            }
        }
        if (anahtar) {
            [self setBekliyor:NO];
        } else if ([self bekliyorMu]) {
            return;
        }
        // Kuyruk birikmesin: hazır değilse kareyi at. Atılan kare sonrakilerin
        // referansı olduğu için bir sonraki anahtar kareye kadar bekle.
        // AirPlay anahtar kareyi seyrek yolluyor; orada atmak görüntüyü uzun süre
        // dondurur, bu yüzden kare kuyruğa yine de girer.
        if (!anahtar && !_anahtarSeyrek && !katman.isReadyForMoreMediaData) {
            [self setBekliyor:YES];
            return;
        }
        [katman enqueueSampleBuffer:(__bridge CMSampleBufferRef)tasinan];
    });
}

#pragma mark Ses

- (void)sesPaketi:(const uint8_t *)p uzunluk:(size_t)n {
    __sync_add_and_fetch(&_sesSayaci, 1);
    if (!p || n < 6) return;
    uint32_t hiz = oku32be(p);
    int kanal = p[4];
    if (kanal != 1 && kanal != 2) return;
    if (hiz < 4000 || hiz > 192000) return;

    size_t cerceveBoyu = (size_t)kanal * 2;
    size_t pcmBoyu = n - 5;
    pcmBoyu -= pcmBoyu % cerceveBoyu; // yarım çerçeveyi at
    if (pcmBoyu == 0) return;

    if (!_sesKuyrugu || _sesHizi != (double)hiz || _sesKanali != kanal) {
        [self sesKuyrugunuKur:hiz kanal:kanal];
    }
    [self pcmYaz:p + 5 uzunluk:pcmBoyu];
}

- (void)sesKuyrugunuKur:(uint32_t)hiz kanal:(int)kanal {
    if (_sesKuyrugu) {
        AudioQueueStop(_sesKuyrugu, true);
        AudioQueueDispose(_sesKuyrugu, true);
        _sesKuyrugu = NULL;
    }
    [self halkayiKur:hiz kanal:kanal];

    AudioStreamBasicDescription bicim;
    memset(&bicim, 0, sizeof(bicim));
    bicim.mSampleRate = (Float64)hiz;
    bicim.mFormatID = kAudioFormatLinearPCM;
    bicim.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    bicim.mFramesPerPacket = 1;
    bicim.mChannelsPerFrame = (UInt32)kanal;
    bicim.mBitsPerChannel = 16;
    bicim.mBytesPerFrame = (UInt32)(kanal * 2);
    bicim.mBytesPerPacket = bicim.mBytesPerFrame;

    OSStatus durum = AudioQueueNewOutput(&bicim, SesGeriCagirma,
                                         (__bridge void *)self,
                                         NULL, NULL, 0, &_sesKuyrugu);
    if (durum != noErr || !_sesKuyrugu) {
        _sesKuyrugu = NULL;
        return;
    }

    _sesHizi = (double)hiz;
    _sesKanali = kanal;

    UInt32 tamponBoyu = 2048 * bicim.mBytesPerFrame; // 3 tampon x 2048 kare
    for (int i = 0; i < 3; i++) {
        AudioQueueBufferRef tampon = NULL;
        durum = AudioQueueAllocateBuffer(_sesKuyrugu, tamponBoyu, &tampon);
        if (durum != noErr || !tampon) {
            AudioQueueDispose(_sesKuyrugu, true);
            _sesKuyrugu = NULL;
            return;
        }
        // Boş (0 bayt) tampon kuyruğa kabul edilmez, geri çağırma hiç başlamaz;
        // ilk turu dolu (gerekirse sessiz) tamponla başlat.
        SesGeriCagirma((__bridge void *)self, _sesKuyrugu, tampon);
    }
    durum = AudioQueueStart(_sesKuyrugu, NULL);
    if (durum != noErr) {
        AudioQueueDispose(_sesKuyrugu, true);
        _sesKuyrugu = NULL;
    }
}

- (void)halkayiKur:(uint32_t)hiz kanal:(int)kanal {
    size_t kapasite = (size_t)((double)hiz * 2.0); // 2 saniyelik yer
    if (kapasite < 4096) kapasite = 4096;
    if (kapasite > (1u << 22)) kapasite = 1u << 22;
    int16_t *yeni = (int16_t *)calloc(kapasite * (size_t)kanal, sizeof(int16_t));

    pthread_mutex_lock(&_halkaKilit);
    free(_halka.veri);
    _halka.veri = yeni;
    _halka.kapasiteKare = yeni ? kapasite : 0;
    _halka.kanal = (size_t)kanal;
    _halka.bas = 0;
    _halka.adet = 0;
    pthread_mutex_unlock(&_halkaKilit);
}

- (void)sesTamponunuTemizle {
    pthread_mutex_lock(&_halkaKilit);
    _halka.bas = 0;
    _halka.adet = 0;
    pthread_mutex_unlock(&_halkaKilit);
}

- (void)pcmYaz:(const uint8_t *)p uzunluk:(size_t)n {
    pthread_mutex_lock(&_halkaKilit);
    if (!_halka.veri || _halka.kapasiteKare == 0 || _halka.kanal == 0) {
        pthread_mutex_unlock(&_halkaKilit);
        return;
    }
    size_t kanal = _halka.kanal;
    size_t cerceveBoyu = kanal * 2;
    size_t kare = n / cerceveBoyu;
    const uint8_t *kaynak = p;

    if (kare > _halka.kapasiteKare) { // tampondan büyük pakette son kısmı al
        size_t at = kare - _halka.kapasiteKare;
        kaynak += at * cerceveBoyu;
        kare = _halka.kapasiteKare;
    }

    size_t bos = _halka.kapasiteKare - _halka.adet;
    if (kare > bos) { // yer açmak için en eskileri at
        size_t at = kare - bos;
        _halka.bas = (_halka.bas + at) % _halka.kapasiteKare;
        _halka.adet -= at;
    }

    size_t yaz = (_halka.bas + _halka.adet) % _halka.kapasiteKare;
    size_t ilk = kare;
    if (ilk > _halka.kapasiteKare - yaz) ilk = _halka.kapasiteKare - yaz;
    memcpy(_halka.veri + yaz * kanal, kaynak, ilk * cerceveBoyu);
    if (kare > ilk) {
        memcpy(_halka.veri, kaynak + ilk * cerceveBoyu, (kare - ilk) * cerceveBoyu);
    }
    _halka.adet += kare;

    // 0,5 saniyeden fazla biriktiyse en eskileri at (gecikme büyümesin).
    size_t sinir = _halka.kapasiteKare / 4; // kapasite 2 sn => 0,5 sn
    if (_halka.adet > sinir) {
        size_t at = _halka.adet - sinir;
        _halka.bas = (_halka.bas + at) % _halka.kapasiteKare;
        _halka.adet -= at;
    }
    pthread_mutex_unlock(&_halkaKilit);
}

- (void)sesTamponuDoldur:(AudioQueueBufferRef)tampon {
    size_t kanal = 1;
    pthread_mutex_lock(&_halkaKilit);
    if (_halka.kanal > 0) kanal = _halka.kanal;
    size_t cerceveBoyu = kanal * 2;
    size_t istenen = tampon->mAudioDataBytesCapacity / cerceveBoyu;
    int16_t *cikis = (int16_t *)tampon->mAudioData;
    size_t alinan = 0;

    if (_halka.veri && _halka.kapasiteKare > 0) {
        alinan = _halka.adet < istenen ? _halka.adet : istenen;
        size_t ilk = alinan;
        if (ilk > _halka.kapasiteKare - _halka.bas) ilk = _halka.kapasiteKare - _halka.bas;
        memcpy(cikis, _halka.veri + _halka.bas * kanal, ilk * cerceveBoyu);
        if (alinan > ilk) {
            memcpy(cikis + ilk * kanal, _halka.veri, (alinan - ilk) * cerceveBoyu);
        }
        _halka.bas = (_halka.bas + alinan) % _halka.kapasiteKare;
        _halka.adet -= alinan;
    }
    pthread_mutex_unlock(&_halkaKilit);

    if (alinan < istenen) { // kalanı sessizlikle doldur
        memset(cikis + alinan * kanal, 0, (istenen - alinan) * cerceveBoyu);
    }
    tampon->mAudioDataByteSize = (UInt32)(istenen * cerceveBoyu);
}

@end

#pragma mark - Görünüm denetleyicisi

@interface GorunumDenetleyicisi : UIViewController
@end

@implementation GorunumDenetleyicisi {
    AVSampleBufferDisplayLayer *_videoKatmani;
    UILabel *_durumEtiketi;
    Alici *_replayAlici;
    Alici *_airplayAlici;
    NSTimer *_durumZamanlayici;
    int _karesizSaniye;
    BOOL _goruntuGeldi; // açılıştaki bekleyişi kesintiden ayırmak için
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    _videoKatmani = [[AVSampleBufferDisplayLayer alloc] init];
    _videoKatmani.videoGravity = AVLayerVideoGravityResizeAspect;
    _videoKatmani.backgroundColor = [UIColor blackColor].CGColor;
    _videoKatmani.frame = self.view.bounds;
    _videoKatmani.contentsScale = [UIScreen mainScreen].scale;
    [self.view.layer addSublayer:_videoKatmani];

    _durumEtiketi = [[UILabel alloc] initWithFrame:CGRectMake(8, 8, 360, 20)];
    _durumEtiketi.text = kDurumBekliyor;
    _durumEtiketi.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    _durumEtiketi.font = [UIFont systemFontOfSize:12.0];
    _durumEtiketi.backgroundColor = [UIColor clearColor];
    _durumEtiketi.userInteractionEnabled = NO;
    [self.view addSubview:_durumEtiketi];

    UITapGestureRecognizer *dokunma =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(durumuDegistir)];
    dokunma.numberOfTapsRequired = 1;
    [self.view addGestureRecognizer:dokunma];

    // Ses oturumu: yalnızca çalma, uygulama öndeyken etkin.
    NSError *hata = nil;
    AVAudioSession *oturum = [AVAudioSession sharedInstance];
    [oturum setCategory:AVAudioSessionCategoryPlayback error:&hata];
    [oturum setActive:YES error:&hata];

    _replayAlici = [[Alici alloc] initWithKatman:_videoKatmani
                                            host:"172.20.10.1"
                                            port:8889
                                              ad:@"ReplayKit"];
    [_replayAlici baslat];
    _airplayAlici = [[Alici alloc] initWithKatman:_videoKatmani
                                             host:"127.0.0.1"
                                             port:7101
                                               ad:@"AirPlay"];
    [_airplayAlici baslat];

    _durumZamanlayici = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                         target:self
                                                       selector:@selector(durumuGuncelle)
                                                       userInfo:nil
                                                        repeats:YES];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _videoKatmani.frame = self.view.bounds;
}

- (void)durumuGuncelle {
    int32_t replayKare = [_replayAlici kareSayaciniSifirla];
    int32_t replaySes = [_replayAlici sesSayaciniSifirla];
    int32_t airplayKare = [_airplayAlici kareSayaciniSifirla];
    int32_t airplaySes = [_airplayAlici sesSayaciniSifirla];
    int32_t kare = replayKare + airplayKare;
    int32_t ses = replaySes + airplaySes;
    BOOL replayBagli = [_replayAlici bagliMi];
    BOOL airplayBagli = [_airplayAlici bagliMi];
    BOOL airplayEtkin = [[EtkinKaynak paylasilan] etkinMi:_airplayAlici.ad];

    // Durağan ekranda ReplayKit kare yollamayabilir; kesinti sayılması için ses de susmalı.
    if (kare > 0 || ses > 0) {
        _karesizSaniye = 0;
        _goruntuGeldi = YES;
    } else {
        _karesizSaniye++;
    }

    if (_goruntuGeldi && _karesizSaniye >= 5) {
        // Arama gibi kesintide bağlantı kalsa da kare gelmeyebilir; kullanıcıya açıkça göster.
        if (airplayEtkin) {
            _durumEtiketi.text = [NSString stringWithFormat:@"görüntü yok (%d sn) • iPhone'da Ekran Yansıtma'yı yeniden seç", _karesizSaniye];
        } else {
            _durumEtiketi.text = [NSString stringWithFormat:@"görüntü yok (%d sn) • arama bitince kendiliğinden döner, dönmezse iPhone'da yayını yeniden başlat", _karesizSaniye];
        }
        _durumEtiketi.hidden = NO;
    } else if ((airplayEtkin && airplayBagli) || replayBagli) {
        // AirPlay daemon'u hep dinlediği için bağlantısı tek başına yansıtma demek
        // değil; yansıtma ancak daemon 'V' yollayınca (etkin) sayılır.
        Alici *kaynak = (airplayEtkin && airplayBagli) ? _airplayAlici : _replayAlici;
        _durumEtiketi.text = [NSString stringWithFormat:@"%@ • bağlandı • %d kare/sn • ses %d paket/sn • %@",
                              kaynak.ad, kare, ses, [kaynak sesDurumu]];
    } else {
        _durumEtiketi.text = kDurumBekliyor;
    }
    [_durumEtiketi sizeToFit];
    CGRect cerceve = _durumEtiketi.frame;
    cerceve.origin = CGPointMake(8, 8);
    _durumEtiketi.frame = cerceve;
}

- (void)durumuDegistir {
    _durumEtiketi.hidden = !_durumEtiketi.hidden;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAll;
}

- (void)dealloc {
    [_durumZamanlayici invalidate];
    [_replayAlici durdur];
    [_airplayAlici durdur];
}

@end

#pragma mark - Uygulama temsilcisi

@interface UygulamaTemsilcisi : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation UygulamaTemsilcisi

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [UIApplication sharedApplication].idleTimerDisabled = YES; // ekran kapanmasın

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor blackColor];
    self.window.rootViewController = [[GorunumDenetleyicisi alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

- (UIInterfaceOrientationMask)application:(UIApplication *)application
  supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    return UIInterfaceOrientationMaskAll;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([UygulamaTemsilcisi class]));
    }
}
