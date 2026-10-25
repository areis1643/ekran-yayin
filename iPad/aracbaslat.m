#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <ifaddrs.h>
#import <netinet/in.h>
#import <stdbool.h>
#import <unistd.h>

typedef int (*UygulamaAc)(CFStringRef identifier, Boolean suspended);

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

int main(int argc, char *argv[]) {
    @autoreleasepool {
        void *kitaplik = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
        UygulamaAc uygulamaAc = kitaplik ? (UygulamaAc)dlsym(kitaplik, "SBSLaunchApplicationWithIdentifier") : NULL;
        if (!uygulamaAc) NSLog(@"aracbaslat açma API'si yüklenemedi: %s", dlerror());

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
            }
            sleep(3);
        }
    }
}
