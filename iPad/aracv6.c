/* aracv6: iPad iPhone erişim noktasındayken en0'da IPv6'yı kapatır (root).
 *
 * 31 Eki 2026: iPhone erişim noktasından gelen IPv6 TCP paketlerinin sağlama toplamı
 * bozuk (IPv4 temiz); iPad çekirdeği onları atıyor. iPhone yansıtmada IPv6'yı seçerse
 * "Araç Ekran" listede görünüp bağlanmıyordu (bkz. AIRPLAY-POC.md 9. adım). en0'da IPv6
 * adresi yoksa Bonjour yalnız A kaydı verir, iPhone IPv4 ile bağlanmak zorunda kalır.
 * Başka bir ağa geçince (ev, klinik) IPv6 geri açılır. */
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

static void yaz(const char *fmt, ...) {
    char zaman[32]; time_t t = time(NULL); struct tm tm; localtime_r(&t, &tm);
    strftime(zaman, sizeof zaman, "%Y-%m-%d %H:%M:%S", &tm);
    fprintf(stderr, "%s ", zaman);
    va_list a; va_start(a, fmt); vfprintf(stderr, fmt, a); va_end(a);
    fputc('\n', stderr);
}

/* en0'ın IPv4 adresini (yoksa 0) ve IPv6 adresi olup olmadığını döndürür. */
static void durum(uint32_t *v4, int *v6) {
    struct ifaddrs *liste, *i;
    *v4 = 0; *v6 = 0;
    if (getifaddrs(&liste)) return;
    for (i = liste; i; i = i->ifa_next) {
        /* SDK kütüğünde strcmp yok, elle karşılaştır. */
        const char *ad = i->ifa_name;
        if (!i->ifa_addr || !ad || ad[0] != 'e' || ad[1] != 'n' || ad[2] != '0' || ad[3]) continue;
        if (i->ifa_addr->sa_family == AF_INET) *v4 = ntohl(((struct sockaddr_in *)i->ifa_addr)->sin_addr.s_addr);
        else if (i->ifa_addr->sa_family == AF_INET6) *v6 = 1;
    }
    freeifaddrs(liste);
}

static int ipconfig(const char *kip) {
    char *arg[] = {"/usr/sbin/ipconfig", "set", "en0", (char *)kip, NULL};
    pid_t pid; int st = -1;
    if (posix_spawn(&pid, arg[0], NULL, NULL, arg, environ)) return -1;
    if (waitpid(pid, &st, 0) < 0) return -1;
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

int main(void) {
    setvbuf(stderr, NULL, _IOLBF, 0);
    yaz("aracv6 basladi uid=%d", (int)getuid());
    int kapattik = 0;
    time_t son_kapatma = 0;
    unsigned tekrar = 0;
    for (;;) {
        uint32_t v4; int v6;
        durum(&v4, &v6);
        int hotspot = (v4 & 0xFFFFFFF0u) == 0xAC140A00u;   /* 172.20.10.0/28 */
        if (hotspot && v6) {
            time_t simdi = time(NULL);
            /* iOS adresi geri koyarsa sürekli komut basmayalım: en sık 5 sn'de bir. */
            if (simdi - son_kapatma >= 5) {
                int r = ipconfig("NONE-V6");
                tekrar = kapattik ? tekrar + 1 : 0;
                yaz("erisim noktasi %u.%u.%u.%u: IPv6 kapatildi (sonuc %d%s)", v4 >> 24, (v4 >> 16) & 255,
                    (v4 >> 8) & 255, v4 & 255, r, tekrar ? ", adres geri gelmisti" : "");
                son_kapatma = simdi; kapattik = 1;
            }
        } else if (!hotspot && v4 && kapattik) {
            int r = ipconfig("AUTOMATIC-V6");
            yaz("baska ag %u.%u.%u.%u: IPv6 geri acildi (sonuc %d)", v4 >> 24, (v4 >> 16) & 255,
                (v4 >> 8) & 255, v4 & 255, r);
            kapattik = 0; tekrar = 0;
        }
        usleep(500000);
    }
}
