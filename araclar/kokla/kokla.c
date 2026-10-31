/* kokla: iPad'de en0'dan geçen paketlerin özetini BPF ile yazar (tcpdump yok).
 *   kokla [saniye]   varsayılan 60
 * Yazdığı: TCP 7000/7100 (AirPlay), UDP 5353 (Bonjour; içindeki okunur adlarla), ARP.
 * 31 Eki: iPhone "Araç Ekran"ı seçince daemon'a hiç bağlantı gelmiyordu; SYN iPad'e
 * ulaşıyor mu, Bonjour hangi adresi veriyor görmek için yazıldı. */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <net/if.h>
#include <arpa/inet.h>

struct bpf_hdr32 { int32_t sec, usec; uint32_t caplen, datalen; uint16_t hdrlen; };
#define BIOCGBLEN _IOR('B', 102, unsigned int)
#define BIOCSBLEN _IOWR('B', 102, unsigned int)
#define BIOCPROMISC _IO('B', 105)
#define BIOCSETIF _IOW('B', 108, struct ifreq)
#define BIOCIMMEDIATE _IOW('B', 112, unsigned int)
#define BIOCSRTIMEOUT _IOW('B', 109, struct timeval)
#define WALIGN(x) (((x) + 3) & ~3u)

static void zaman(void) {
    struct timeval tv; gettimeofday(&tv, NULL);
    struct tm t; localtime_r(&tv.tv_sec, &t);
    printf("%02d:%02d:%02d.%03d ", t.tm_hour, t.tm_min, t.tm_sec, (int)(tv.tv_usec / 1000));
}

static void adlar(const unsigned char *p, size_t n) {
    /* mDNS içindeki okunur parçaları sırayla yaz, A kayıtlarını ayrıca ara. */
    char buf[600]; size_t b = 0, run = 0;
    for (size_t i = 0; i < n && b < sizeof buf - 2; i++) {
        unsigned char c = p[i];
        if (c >= 0x20 && c < 0x7f) { buf[b++] = (char)c; run++; }
        else if (c >= 0xc3 && c <= 0xc5 && i + 1 < n) { buf[b++] = (char)c; buf[b++] = (char)p[++i]; run++; }
        else { if (run >= 3) buf[b++] = '|'; else b -= run; run = 0; }
    }
    if (run < 3) b -= run;
    buf[b] = 0;
    printf(" [%s]", buf);
    /* A kaydı: tip 1, sınıf 1 (önbellek bayrağı olabilir), 4 bayt veri */
    for (size_t i = 0; i + 14 <= n; i++)
        if (p[i] == 0 && p[i+1] == 1 && (p[i+2] & 0x7f) == 0 && p[i+3] == 1 && p[i+8] == 0 && p[i+9] == 4)
            printf(" A=%u.%u.%u.%u", p[i+10], p[i+11], p[i+12], p[i+13]);
}

static void paket(const unsigned char *p, size_t n) {
    if (n < 14) return;
    unsigned type = (unsigned)p[12] << 8 | p[13];
    const unsigned char *ip = p + 14; size_t m = n - 14;
    if (type == 0x0806 && m >= 28) {
        zaman();
        printf("ARP %s %u.%u.%u.%u -> %u.%u.%u.%u\n", ip[7] == 1 ? "kim" : "cevap",
               ip[14], ip[15], ip[16], ip[17], ip[24], ip[25], ip[26], ip[27]);
        return;
    }
    char s[64], d[64]; unsigned proto; const unsigned char *l4; size_t l4n;
    if (type == 0x0800 && m >= 20) {
        unsigned hl = (ip[0] & 15) * 4; if (m < hl) return;
        proto = ip[9]; inet_ntop(AF_INET, ip + 12, s, sizeof s); inet_ntop(AF_INET, ip + 16, d, sizeof d);
        l4 = ip + hl; l4n = m - hl;
    } else if (type == 0x86dd && m >= 40) {
        proto = ip[6]; inet_ntop(AF_INET6, ip + 8, s, sizeof s); inet_ntop(AF_INET6, ip + 24, d, sizeof d);
        l4 = ip + 40; l4n = m - 40;
    } else return;
    if (proto == 58 && l4n >= 4) {   /* ICMPv6: 133-137 komşu keşfi */
        zaman();
        char hedef[64] = "";
        if ((l4[0] == 135 || l4[0] == 136) && l4n >= 24) inet_ntop(AF_INET6, l4 + 8, hedef, sizeof hedef);
        printf("ICMPv6 %s -> %s tip=%u %s%s (hedef MAC %02x:%02x:%02x:%02x:%02x:%02x)\n", s, d, l4[0],
               l4[0] == 135 ? "NS " : l4[0] == 136 ? "NA " : l4[0] == 134 ? "RA " : l4[0] == 133 ? "RS " : "", hedef,
               p[0], p[1], p[2], p[3], p[4], p[5]);
        return;
    }
    if (l4n < 8) return;
    unsigned sp = (unsigned)l4[0] << 8 | l4[1], dp = (unsigned)l4[2] << 8 | l4[3];
    if (proto == 6) {
        int ilgili = sp == 7000 || dp == 7000 || sp == 7100 || dp == 7100 || sp == 7001 || dp == 7001 || sp == 7101 || dp == 7101;
        if (!ilgili && !(l4n >= 14 && (l4[13] & 0x02))) return;   /* başka portlarda yalnız SYN */
        unsigned f = l4n >= 14 ? l4[13] : 0;
        zaman();
        /* TCP sağlama toplamı: sözde başlık + segment; doğruysa toplam 0xffff */
        uint32_t sum = 0;
        if (type == 0x86dd) { for (int i = 8; i < 40; i += 2) sum += (uint32_t)ip[i] << 8 | ip[i+1]; }
        else { for (int i = 12; i < 20; i += 2) sum += (uint32_t)ip[i] << 8 | ip[i+1]; }
        sum += 6 + (uint32_t)l4n;
        for (size_t i = 0; i + 1 < l4n; i += 2) sum += (uint32_t)l4[i] << 8 | l4[i+1];
        if (l4n & 1) sum += (uint32_t)l4[l4n-1] << 8;
        while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
        printf("TCP %s:%u -> %s:%u %s%s%s%s len=%zu sum=%s mac %02x:%02x:%02x:%02x:%02x:%02x>%02x:%02x:%02x:%02x:%02x:%02x\n", s, sp, d, dp, f & 2 ? "SYN " : "", f & 16 ? "ACK " : "",
               f & 4 ? "RST " : "", f & 1 ? "FIN " : "", l4n, sum == 0xffff ? "ok" : "BOZUK",
               p[6], p[7], p[8], p[9], p[10], p[11], p[0], p[1], p[2], p[3], p[4], p[5]);
        if (sum != 0xffff && getenv("HEX")) { printf("  IP+TCP:"); for (size_t i = 0; i < 40 + l4n && i < 120; i++) printf("%02x", ip[i]); printf(" topl=%04x\n", sum); }
    } else if (proto == 17 && (sp == 5353 || dp == 5353)) {
        zaman();
        printf("mDNS %s:%u -> %s:%u len=%zu", s, sp, d, dp, l4n - 8);
        adlar(l4 + 8 + 12, l4n > 20 ? l4n - 20 : 0);
        printf("\n");
    }
}

int main(int argc, char **argv) {
    int sure = argc > 1 ? atoi(argv[1]) : 60;
    int fd = -1; char dev[16];
    for (int i = 0; i < 64 && fd < 0; i++) { snprintf(dev, sizeof dev, "/dev/bpf%d", i); fd = open(dev, O_RDONLY); }
    if (fd < 0) { perror("bpf"); return 1; }
    unsigned blen = 65536; ioctl(fd, BIOCSBLEN, &blen);
    struct ifreq ifr; memset(&ifr, 0, sizeof ifr); strcpy(ifr.ifr_name, "en0");
    if (ioctl(fd, BIOCSETIF, &ifr) < 0) { perror("BIOCSETIF en0"); return 1; }
    unsigned one = 1; ioctl(fd, BIOCIMMEDIATE, &one);
    ioctl(fd, BIOCPROMISC, NULL);
    struct timeval rto = {1, 0}; ioctl(fd, BIOCSRTIMEOUT, &rto);
    if (ioctl(fd, BIOCGBLEN, &blen) < 0) blen = 4096;
    unsigned char *buf = malloc(blen);
    setvbuf(stdout, NULL, _IOLBF, 0);
    zaman(); printf("kokla basladi %s, %d sn\n", dev, sure);
    time_t bitis = time(NULL) + sure;
    while (time(NULL) < bitis) {
        ssize_t r = read(fd, buf, blen);
        if (r <= 0) continue;
        for (unsigned char *q = buf; q < buf + r;) {
            struct bpf_hdr32 *h = (struct bpf_hdr32 *)q;
            if (h->hdrlen == 0) break;
            paket(q + h->hdrlen, h->caplen);
            q += WALIGN(h->hdrlen + h->caplen);
        }
    }
    zaman(); printf("kokla bitti\n");
    return 0;
}
