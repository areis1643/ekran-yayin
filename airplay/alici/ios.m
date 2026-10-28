#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <dispatch/dispatch.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "ios.h"

extern void logline(const char *fmt, ...);
enum { KAPASITE = 44100 * 2, SINIR = 44100 / 4, ZAMANLI_SINIR = 44100 * 3 / 2 };
/* Zamanlı çalmada bu kadardan küçük kayma düzeltilmez (çıtırtı yapmasın). */
static const int64_t kTolerans = 20000000;
static int16_t halka[KAPASITE * 2];
static size_t bas, adet;
/* zamanli: halkadaki örnekler duyulma zamanıyla geliyor; basZaman baştaki örneğin zamanı. */
static int zamanli;
static int64_t basZaman;
static uint64_t atilan, beklenen;
static volatile int64_t cikisGecikmesi;
static mach_timebase_info_data_t saatOrani;
static float kazanc = 1;
static pthread_mutex_t kilit = PTHREAD_MUTEX_INITIALIZER;
static AudioUnit birim;
static dispatch_queue_t sesKuyruk;
static id kesinti, rotaDegisti;

static int64_t gercekZaman(void) {
    struct timespec t;
    clock_gettime(CLOCK_REALTIME, &t);
    return (int64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}
static int64_t ornekNs(size_t n) { return (int64_t)n * 1000000000 / 44100; }

void ses_temizle(void) {
    pthread_mutex_lock(&kilit);
    bas = adet = 0;
    pthread_mutex_unlock(&kilit);
}
void ses_yaz(const int16_t *pcm, size_t kare, uint64_t zaman) {
    if (!pcm || !kare) return;
    if (kare > KAPASITE) { pcm += (kare - KAPASITE) * 2; kare = KAPASITE; }
    pthread_mutex_lock(&kilit);
    int yeniKip = zaman != 0;
    if (yeniKip != zamanli) { bas = adet = 0; zamanli = yeniKip; }
    if (zamanli) {
        /* Ardışık paket beklenen yerdeyse halka kesintisiz sürer; kayıp ya da atlama
         * varsa baştan kurulur. */
        int64_t sonu = basZaman + ornekNs(adet);
        if (!adet || llabs((int64_t)zaman - sonu) > 50000000) { bas = adet = 0; basZaman = (int64_t)zaman; }
    }
    if (kare > KAPASITE - adet) {
        size_t at = kare - (KAPASITE - adet);
        bas = (bas + at) % KAPASITE; adet -= at; basZaman += ornekNs(at);
    }
    size_t yaz = (bas + adet) % KAPASITE;
    size_t ilk = kare < KAPASITE - yaz ? kare : KAPASITE - yaz;
    memcpy(halka + yaz * 2, pcm, ilk * 4);
    memcpy(halka, pcm + ilk * 2, (kare - ilk) * 4);
    adet += kare;
    size_t sinir = zamanli ? ZAMANLI_SINIR : SINIR;
    if (adet > sinir) {
        size_t at = adet - sinir;
        bas = (bas + at) % KAPASITE; adet = sinir; basZaman += ornekNs(at);
    }
    pthread_mutex_unlock(&kilit);
}
void ses_duzey(float db) {
    float yeni = !isfinite(db) || db <= -144 ? 0 : powf(10, fminf(0, fmaxf(-30, db)) / 20);
    pthread_mutex_lock(&kilit); kazanc = yeni; pthread_mutex_unlock(&kilit);
}
int64_t ses_cikis_gecikmesi(void) { return cikisGecikmesi; }
void ses_sayaclar(uint64_t *a, uint64_t *b) {
    pthread_mutex_lock(&kilit);
    *a = atilan; *b = beklenen; atilan = beklenen = 0;
    pthread_mutex_unlock(&kilit);
}
static OSStatus doldur(void *ctx, AudioUnitRenderActionFlags *flags,
                      const AudioTimeStamp *time, UInt32 bus, UInt32 frames, AudioBufferList *io) {
    (void)ctx; (void)bus;
    for (UInt32 b = 0; b < io->mNumberBuffers; b++)
        if (io->mBuffers[b].mData) memset(io->mBuffers[b].mData, 0, io->mBuffers[b].mDataByteSize);
    if (!io->mNumberBuffers || !io->mBuffers[0].mData) return noErr;
    AudioBuffer *buf = &io->mBuffers[0];
    size_t n = frames < buf->mDataByteSize / 4 ? frames : buf->mDataByteSize / 4;
    int16_t *out = buf->mData;
    /* Bu tamponun ilk örneği hoparlörden ne zaman duyulacak (gerçek saatle). */
    int64_t duyulma = 0;
    if (time && (time->mFlags & kAudioTimeStampHostTimeValid)) {
        int64_t simdi = (int64_t)mach_absolute_time();
        int64_t ileri = ((int64_t)time->mHostTime - simdi) * saatOrani.numer / saatOrani.denom;
        duyulma = gercekZaman() + ileri + cikisGecikmesi;
    }
    pthread_mutex_lock(&kilit);
    size_t bosluk = 0;
    if (zamanli && duyulma && adet) {
        int64_t fark = basZaman - duyulma;
        if (fark < -kTolerans) {
            size_t at = (size_t)((-fark) * 44100 / 1000000000);
            if (at > adet) at = adet;
            bas = (bas + at) % KAPASITE; adet -= at; basZaman += ornekNs(at); atilan += at;
        } else if (fark > kTolerans) {
            bosluk = (size_t)(fark * 44100 / 1000000000);
            if (bosluk > n) bosluk = n;
            beklenen += bosluk;
        }
    }
    size_t al = adet < n - bosluk ? adet : n - bosluk;
    float gain = kazanc;
    for (size_t i = 0; i < al; i++) {
        size_t at = ((bas + i) % KAPASITE) * 2;
        out[(bosluk + i) * 2] = (int16_t)(halka[at] * gain);
        out[(bosluk + i) * 2 + 1] = (int16_t)(halka[at + 1] * gain);
    }
    bas = (bas + al) % KAPASITE; adet -= al; basZaman += ornekNs(al);
    pthread_mutex_unlock(&kilit);
    if (!al || gain == 0) *flags |= kAudioUnitRenderAction_OutputIsSilence;
    return noErr;
}
static int durum(const char *yer, OSStatus rc) {
    if (rc) logline("ses %s OSStatus=%d", yer, (int)rc);
    return (int)rc;
}
/* sesKuyruk üstünde çağrılır. Bluetooth hoparlörde outputLatency A2DP gecikmesini içerir. */
static void gecikmeyiOku(void) {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    cikisGecikmesi = (int64_t)((session.outputLatency + session.IOBufferDuration) * 1e9);
    NSMutableArray *adlar = [NSMutableArray array];
    for (AVAudioSessionPortDescription *port in session.currentRoute.outputs)
        [adlar addObject:[NSString stringWithFormat:@"%@ (%@)", port.portName, port.portType]];
    logline("ses cikisi: %s, gecikme %.0f ms (cikis %.0f + tampon %.0f)",
            [adlar componentsJoinedByString:@", "].UTF8String, cikisGecikmesi / 1e6,
            session.outputLatency * 1e3, session.IOBufferDuration * 1e3);
}
void ses_rota_yaz(void) {
    if (sesKuyruk) dispatch_async(sesKuyruk, ^{ @autoreleasepool { gecikmeyiOku(); } });
}
static int etkinlestir(void) {
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (![session setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&error] ||
        ![session setActive:YES error:&error]) {
        logline("ses AVAudioSession: %s (kod=%ld)", error.description.UTF8String, (long)error.code);
        return -1;
    }
    return 0;
}
int ses_baslat(void) {
    @autoreleasepool {
        mach_timebase_info(&saatOrani);
        sesKuyruk = dispatch_queue_create("tr.niladsp.arac.ses", DISPATCH_QUEUE_SERIAL);
        __block int rc = 0;
        dispatch_sync(sesKuyruk, ^{
            @autoreleasepool {
                if ((rc = etkinlestir())) return;
                AudioComponentDescription desc = {kAudioUnitType_Output, kAudioUnitSubType_RemoteIO, kAudioUnitManufacturer_Apple, 0, 0};
                AudioComponent component = AudioComponentFindNext(NULL, &desc);
                if (!component) { logline("ses RemoteIO bulunamadi"); rc = -1; return; }
                if ((rc = durum("instance", AudioComponentInstanceNew(component, &birim)))) return;
                UInt32 enable = 1;
                AudioStreamBasicDescription fmt = {44100, kAudioFormatLinearPCM,
                    kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, 4, 1, 4, 2, 16, 0};
                AURenderCallbackStruct cb = {doldur, NULL};
                if ((rc = durum("enable", AudioUnitSetProperty(birim, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enable, sizeof enable))) ||
                    (rc = durum("format", AudioUnitSetProperty(birim, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, sizeof fmt))) ||
                    (rc = durum("callback", AudioUnitSetProperty(birim, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb))) ||
                    (rc = durum("initialize", AudioUnitInitialize(birim))) ||
                    (rc = durum("start", AudioOutputUnitStart(birim)))) {
                    AudioComponentInstanceDispose(birim); birim = NULL; return;
                }
                gecikmeyiOku();
                kesinti = [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
                    NSUInteger type = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
                    dispatch_async(sesKuyruk, ^{
                        @autoreleasepool {
                            if (!birim) return;
                            durum("interruption stop", AudioOutputUnitStop(birim));
                            ses_temizle();
                            if (type == AVAudioSessionInterruptionTypeEnded && !etkinlestir())
                                durum("interruption restart", AudioOutputUnitStart(birim));
                        }
                    });
                }];
                /* Hoparlör bağlanıp kopunca gecikme değişir (Bluetooth ~150-250 ms). */
                rotaDegisti = [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
                    (void)note; ses_rota_yaz();
                }];
            }
        });
        return rc;
    }
}
void ses_kapat(void) {
    @autoreleasepool {
        if (kesinti) [[NSNotificationCenter defaultCenter] removeObserver:kesinti];
        if (rotaDegisti) [[NSNotificationCenter defaultCenter] removeObserver:rotaDegisti];
        kesinti = rotaDegisti = nil;
        if (sesKuyruk) dispatch_sync(sesKuyruk, ^{
            if (birim) { durum("stop", AudioOutputUnitStop(birim)); AudioUnitUninitialize(birim); AudioComponentInstanceDispose(birim); birim = NULL; }
        });
    }
}
static void *uygulama_isci(void *unused) {
    (void)unused;
    @autoreleasepool {
        void *handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
        typedef int (*Launch)(CFStringRef, Boolean);
        Launch launch = handle ? (Launch)dlsym(handle, "SBSLaunchApplicationWithIdentifier") : NULL;
        if (!launch) logline("Araç acma API hatasi: %s", dlerror());
        int rc = launch ? launch(CFSTR("tr.niladsp.arac"), false) : -1;
        logline("Araç acma sonucu: %d", rc);
        if (handle) dlclose(handle);
    }
    return NULL;
}
int uygulama_ac(void) {
    pthread_t thread;
    pthread_attr_t attr;
    int rc = pthread_attr_init(&attr);
    if (rc) return rc;
    rc = pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    if (!rc) rc = pthread_create(&thread, &attr, uygulama_isci, NULL);
    pthread_attr_destroy(&attr);
    return rc;
}
