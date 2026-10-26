#ifndef ARAC_IOS9_H
#define ARAC_IOS9_H
#include <stdint.h>
#include <libkern/OSByteOrder.h>
#include <time.h>
#include <sys/time.h>
#define htonll(x) OSSwapHostToBigInt64(x)
#define ntohll(x) OSSwapBigToHostInt64(x)
/* iOS 9 has no clock_gettime; UxPlay only requests CLOCK_REALTIME. */
#define CLOCK_REALTIME 0
static inline int arac_clock_gettime(int clock, struct timespec *ts) {
    struct timeval tv;
    (void)clock;
    int rc = gettimeofday(&tv, 0);
    if (!rc) { ts->tv_sec = tv.tv_sec; ts->tv_nsec = tv.tv_usec * 1000; }
    return rc;
}
#define clock_gettime arac_clock_gettime
#endif
