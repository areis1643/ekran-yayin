/* adres6: en0'daki IPv6 adresleri ve bayrakları (ifconfig yok). */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <ifaddrs.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <net/if.h>
#include <netinet/in.h>
#include <arpa/inet.h>
struct in6_ifreq_k { char ifr_name[IFNAMSIZ]; union { struct sockaddr_in6 ifru_addr; int ifru_flags6; char pad[2048]; } ifr_ifru; };
#define SIOCGIFAFLAG_IN6 _IOWR('i', 73, struct in6_ifreq_k)
int main(void) {
    struct ifaddrs *a, *i; if (getifaddrs(&a)) return 1;
    int s = socket(AF_INET6, SOCK_DGRAM, 0);
    for (i = a; i; i = i->ifa_next) {
        if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET6) continue;
        struct sockaddr_in6 *x = (struct sockaddr_in6 *)i->ifa_addr; char b[64];
        inet_ntop(AF_INET6, &x->sin6_addr, b, sizeof b);
        struct in6_ifreq_k r; memset(&r, 0, sizeof r); strncpy(r.ifr_name, i->ifa_name, IFNAMSIZ-1); r.ifr_ifru.ifru_addr = *x;
        int f = -1;
        for (unsigned len = 32; len <= 1024 && f < 0; len += 4) {
            unsigned long cmd = 0xC0000000UL | ((unsigned long)(len & 0x1fff) << 16) | ('i' << 8) | 73;
            struct in6_ifreq_k q = r;
            if (ioctl(s, cmd, &q) == 0) f = q.ifr_ifru.ifru_flags6;
        }
        printf("%s %s scope=%u flags=0x%x%s%s%s%s%s\n", i->ifa_name, b, x->sin6_scope_id, f,
            f>0&&(f&2)?" TENTATIVE":"", f>0&&(f&4)?" DUPLICATED":"", f>0&&(f&8)?" DETACHED":"", f>0&&(f&0x10)?" DEPRECATED":"", f>0&&(f&0x80)?" AUTOCONF":"");
    }
    return 0;
}
