/* baglan6 adres port [arayuz]: IPv6 TCP bağlantısı dener, sonucu yazar. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <net/if.h>
#include <netinet/in.h>
#include <arpa/inet.h>
int main(int c, char **v) {
    if (c < 3) return 2;
    struct sockaddr_in6 a; memset(&a, 0, sizeof a); a.sin6_family = AF_INET6; a.sin6_len = sizeof a;
    a.sin6_port = htons(atoi(v[2])); inet_pton(AF_INET6, v[1], &a.sin6_addr);
    if (c > 3) a.sin6_scope_id = if_nametoindex(v[3]);
    int s = socket(AF_INET6, SOCK_STREAM, 0); fcntl(s, F_SETFL, O_NONBLOCK);
    int r = connect(s, (struct sockaddr *)&a, sizeof a);
    if (r && errno != EINPROGRESS) { printf("%s:%s hemen hata %d %s\n", v[1], v[2], errno, strerror(errno)); return 1; }
    fd_set w; FD_ZERO(&w); FD_SET(s, &w); struct timeval tv = {3, 0};
    if (select(s + 1, NULL, &w, NULL, &tv) <= 0) { printf("%s:%s zaman asimi\n", v[1], v[2]); return 1; }
    int e = 0; socklen_t l = sizeof e; getsockopt(s, SOL_SOCKET, SO_ERROR, &e, &l);
    printf("%s:%s %s\n", v[1], v[2], e ? strerror(e) : "BAGLANDI");
    return 0;
}
