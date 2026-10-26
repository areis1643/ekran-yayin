/* AirPlay mirror to loopback V/F transport and local PCM output. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <inttypes.h>
#include <signal.h>
#include <errno.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <grp.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <time.h>
#include <execinfo.h>
#include <AudioToolbox/AudioToolbox.h>
#include "ios.h"
#include "raop.h"
#include "dnssd.h"
#include "stream.h"
#include "logger.h"

static FILE *logfile;
static pthread_mutex_t loglock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t videolock = PTHREAD_MUTEX_INITIALIZER;
static volatile sig_atomic_t stopping;
static uint64_t frames, skipped, keyframes;
static int client = -1, listener = -1, waiting_idr = 1, debug_logs;
static pthread_t accept_thread;
static unsigned char *cached_sps, *cached_pps, *cached_v;
static size_t cached_sps_len, cached_pps_len, cached_v_len;
static int warned_hevc;
#define GOP_LIMIT (16U * 1024U * 1024U)
static unsigned char *cached_gop;
static size_t cached_gop_len, cached_gop_capacity, cached_gop_frames;
static struct timeval last_sent;

void logline(const char *fmt, ...);
static void clear_gop(void) {
    free(cached_gop); cached_gop=NULL;
    cached_gop_len=cached_gop_capacity=cached_gop_frames=0;
}
static void cache_frame(const unsigned char *p, size_t n, int key) {
    if (key) clear_gop();
    else if (!cached_gop_frames) return;
    if (n>GOP_LIMIT-cached_gop_len) {
        clear_gop(); logline("GOP önbelleği taştı"); return;
    }
    size_t needed=cached_gop_len+n;
    if (needed>cached_gop_capacity) {
        size_t capacity=cached_gop_capacity?cached_gop_capacity:4096;
        while (capacity<needed) capacity*=2;
        if (capacity>GOP_LIMIT) capacity=GOP_LIMIT;
        unsigned char *copy=realloc(cached_gop,capacity);
        if (!copy) { clear_gop(); logline("GOP önbelleği: bellek yetersiz"); return; }
        cached_gop=copy; cached_gop_capacity=capacity;
    }
    memcpy(cached_gop+cached_gop_len,p,n);
    cached_gop_len+=n; cached_gop_frames++;
}

static unsigned char *last_sps;
static size_t last_sps_len;
void logline(const char *fmt, ...) {
    char msg[8192], stamp[40];
    va_list ap;
    va_start(ap, fmt); vsnprintf(msg, sizeof msg, fmt, ap); va_end(ap);
    pthread_mutex_lock(&loglock);
    time_t now = time(NULL); struct tm tm;
    localtime_r(&now, &tm); strftime(stamp, sizeof stamp, "%Y-%m-%d %H:%M:%S%z", &tm);
    char *p = msg;
    do {
        char *end = strchr(p, '\n'); if (end) *end = 0;
        fprintf(stdout, "%s %s\n", stamp, p);
        if (logfile) fprintf(logfile, "%s %s\n", stamp, p);
        if (!end || !end[1]) break;
        p = end + 1;
    } while (1);
    fflush(stdout); if (logfile) fflush(logfile);
    pthread_mutex_unlock(&loglock);
}
static void library_log(void *c, int level, const char *msg) { (void)c; if (debug_logs || level <= LOGGER_WARNING) logline("UxPlay[%d] %s", level, msg); }
static void caught(int sig) { (void)sig; stopping = 1; }
/* Cihazda ReportCrash bu daemon için rapor yazmıyor; çöküşü günlüğe kendimiz düşeriz. */
static void crashed(int sig) {
    void *frames_bt[48];
    int n=backtrace(frames_bt,48);
    char msg[64];
    int len=snprintf(msg,sizeof msg,"COKTU sinyal=%d\n",sig);
    if (logfile) { write(fileno(logfile),msg,(size_t)len); backtrace_symbols_fd(frames_bt,n,fileno(logfile)); }
    write(2,msg,(size_t)len); backtrace_symbols_fd(frames_bt,n,2);
    signal(sig,SIG_DFL); raise(sig);
}
static void exited(void) { if (!stopping) logline("beklenmeyen exit()"); }
/* iOS 9 launchd, /Library'deki plist'in JetsamProperties'ini yok sayıyor: daemon
 * öncelik 0 (boşta bandı) ve 5 MB sınırla kalıyor, video oynarken GOP önbelleği
 * büyüyünce jetsam rapor bırakmadan öldürüyor. Sınırı root iken kendimiz koyup
 * ses oturumu için mobile kullanıcısına iniyoruz. */
typedef struct { int32_t priority; uint64_t user_data; } jetsam_props;
static int jetsam_rc[2] = {-1, -1};
static int drop_root(void) {
    if (getuid() != 0) return 0;
    jetsam_props p = {15, 0};
    jetsam_rc[0] = syscall(440, 2, getpid(), 0, &p, sizeof p);      /* SET_PRIORITY_PROPERTIES */
    jetsam_rc[1] = syscall(440, 6, getpid(), 64, NULL, 0);          /* SET_JETSAM_TASK_LIMIT */
    if (jetsam_rc[1]) jetsam_rc[1] = syscall(440, 5, getpid(), 64, NULL, 0); /* HIGH_WATER_MARK */
    if (initgroups("mobile", 501) || setgid(501) || setuid(501)) return -1;
    setenv("HOME", "/var/mobile", 1); setenv("USER", "mobile", 1); setenv("LOGNAME", "mobile", 1);
    return 0;
}

typedef struct { const unsigned char *p; size_t bits, pos; int bad; } bits_t;
static uint32_t readbits(bits_t *b, unsigned n) {
    if (n > 32 || b->pos > b->bits || n > b->bits-b->pos) { b->bad = 1; return 0; }
    uint32_t v = 0;
    while (n--) { v = (v << 1) | ((b->p[b->pos/8] >> (7-b->pos%8)) & 1); b->pos++; }
    return v;
}
static uint32_t ue(bits_t *b) {
    unsigned n = 0;
    while (!b->bad && !readbits(b, 1)) { if (++n > 30) { b->bad = 1; return 0; } }
    return b->bad ? 0 : ((1U << n)-1 + readbits(b, n));
}
static int32_t se(bits_t *b) { uint32_t v = ue(b); return (v&1) ? (int32_t)((v+1)/2) : -(int32_t)(v/2); }
static void scaling(bits_t *b, int n) {
    int last = 8, next = 8;
    for (int i=0; i<n && !b->bad; i++) { if (next) next = (last + se(b) + 256) % 256; if (next) last = next; }
}
static void sps(const unsigned char *p, size_t len) {
    if (len == last_sps_len && last_sps && !memcmp(p, last_sps, len)) return;
    unsigned char *save = malloc(len), *rbsp = malloc(len);
    if (!save || !rbsp) { free(save); free(rbsp); logline("SPS: bellek yetersiz"); return; }
    memcpy(save, p, len); free(last_sps); last_sps = save; last_sps_len = len;
    size_t n=0; unsigned zeros=0;
    for (size_t i=1; i<len; i++) {
        if (zeros >= 2 && p[i] == 3) { zeros=0; continue; }
        rbsp[n++] = p[i]; zeros = p[i] == 0 ? zeros+1 : 0;
    }
    bits_t b = {rbsp, n*8, 0, 0};
    unsigned profile=readbits(&b,8), constraints=readbits(&b,8), level=readbits(&b,8);
    ue(&b); unsigned chroma=1, separate=0;
    switch (profile) {
    case 100: case 110: case 122: case 244: case 44: case 83: case 86:
    case 118: case 128: case 138: case 139: case 134: case 135:
        chroma=ue(&b); if (chroma>3) b.bad=1;
        if (chroma==3) separate=readbits(&b,1);
        ue(&b); ue(&b); readbits(&b,1);
        if (readbits(&b,1)) for (unsigned i=0; i<(chroma==3?12U:8U) && !b.bad; i++)
            if (readbits(&b,1)) scaling(&b, i<6?16:64);
    }
    ue(&b); unsigned order=ue(&b);
    if (order==0) ue(&b);
    else if (order==1) {
        readbits(&b,1); se(&b); se(&b); unsigned count=ue(&b);
        if (count>255) b.bad=1;
        for (unsigned i=0; i<count && !b.bad; i++) se(&b);
    } else if (order>2) b.bad=1;
    ue(&b); readbits(&b,1);
    unsigned wm=ue(&b), hm=ue(&b), frame=readbits(&b,1);
    if (!frame) readbits(&b,1);
    readbits(&b,1);
    unsigned left=0,right=0,top=0,bottom=0;
    if (readbits(&b,1)) { left=ue(&b); right=ue(&b); top=ue(&b); bottom=ue(&b); }
    unsigned ca=separate?0:chroma;
    unsigned cx=ca==1 || ca==2 ? 2 : 1, cy=(ca==1?2:1)*(2-frame);
    uint64_t w=((uint64_t)wm+1)*16, h=((uint64_t)hm+1)*16*(2-frame);
    uint64_t cropw=((uint64_t)left+right)*cx, croph=((uint64_t)top+bottom)*cy;
    if (b.bad || cropw>=w || croph>=h) logline("Yeni H264 SPS: gecersiz/kesilmis (%zu bayt)", len);
    else logline("Yeni H264 SPS: profile_idc=%u (%s) constraints=0x%02x level_idc=%u chroma_format_idc=%u separate_colour_plane=%u pic_width_in_mbs=%u pic_height_in_map_units=%u frame_mbs_only=%u crop L/R/T/B=%u/%u/%u/%u coded=%"PRIu64"x%"PRIu64" pixels=%"PRIu64"x%"PRIu64,
        profile,profile==66?"Baseline":profile==77?"Main":profile==100?"High":"UNKNOWN",constraints,level,chroma,separate,wm+1,hm+1,frame,left,right,top,bottom,w,h,w-cropw,h-croph);
    free(rbsp);
}
/* All transport/cache state is protected by videolock. */
static void put32(unsigned char *p, size_t n) {
    p[0]=(unsigned char)(n>>24); p[1]=(unsigned char)(n>>16);
    p[2]=(unsigned char)(n>>8); p[3]=(unsigned char)n;
}
static void disconnect_client(void) {
    if (client >= 0) { shutdown(client,SHUT_RDWR); close(client); client=-1; logline("Araç koptu"); }
    waiting_idr=1;
}
static int send_packet(const unsigned char *p, size_t n) {
    while (n) {
        ssize_t k=send(client,p,n,0);
        if (k<0 && errno==EINTR && !stopping) continue;
        if (k<=0) { disconnect_client(); return -1; }
        p+=k; n-=(size_t)k;
    }
    gettimeofday(&last_sent,NULL);
    return 0;
}
static size_t startcode(const unsigned char *p, size_t n, size_t i) {
    if (n-i>=3 && !p[i] && !p[i+1]) {
        if (p[i+2]==1) return 3;
        if (n-i>=4 && !p[i+2] && p[i+3]==1) return 4;
    }
    return 0;
}
/* Iterator accepts both Annex-B prefixes and strips trailing_zero_8bits. */
static int next_nal(const unsigned char *p,size_t n,size_t *pos,const unsigned char **nal,size_t *len) {
    size_t i=*pos, k;
    while (i<n && !(k=startcode(p,n,i))) i++;
    if (i==n) return 0;
    size_t begin=i+k, end=begin;
    while (end<n && !startcode(p,n,end)) end++;
    *pos=end;
    size_t trimmed=end;
    while (trimmed>begin && !p[trimmed-1]) trimmed--;
    *nal=p+begin; *len=trimmed-begin;
    return 1;
}
static int cache_nal(unsigned char **dst,size_t *len,const unsigned char *p,size_t n) {
    if (!n || n>65535 || (*len==n && !memcmp(*dst,p,n))) return 0;
    unsigned char *copy=malloc(n);
    if (!copy) return -1;
    memcpy(copy,p,n); free(*dst); *dst=copy; *len=n; return 1;
}
static void video(void *c, raop_ntp_t *ntp, video_decode_struct *d) {
    (void)c; (void)ntp;
    pthread_mutex_lock(&videolock);
    frames++;
    if (d->is_h265) {
        if (!warned_hevc) { logline("HEVC desteklenmiyor; kareler atiliyor"); warned_hevc=1; }
        skipped++; goto out;
    }
    if (!d->data || d->data_len<=0) { skipped++; goto out; }
    size_t pos=0,n=(size_t)d->data_len,len,payload=1;
    const unsigned char *nal;
    int changed=0,key=0,failed=0;
    while (next_nal(d->data,n,&pos,&nal,&len)) {
        if (!len) continue;
        unsigned type=nal[0]&31;
        if (type==7 || type==8) {
            if (len>65535) { failed=1; continue; }
            int rc=type==7?cache_nal(&cached_sps,&cached_sps_len,nal,len):cache_nal(&cached_pps,&cached_pps_len,nal,len);
            if (rc<0) failed=1;
            else if (rc) { changed=1; if(type==7) sps(nal,len); }
        } else if (type!=9) { payload+=4+len; if(type==5) key=1; }
    }
    if (key) keyframes++;
    if (changed) { clear_gop(); waiting_idr=1; }
    if (failed) { clear_gop(); disconnect_client(); skipped++; goto out; }
    if (cached_sps_len && cached_pps_len) {
        size_t vlen=9+cached_sps_len+cached_pps_len;
        /* Retry building the cache after an allocation failure. */
        if (changed || !cached_v) {
            unsigned char *v=malloc(vlen);
            if (!v) { free(cached_v); cached_v=NULL; cached_v_len=0; disconnect_client(); skipped++; goto out; }
            v[0]='V'; put32(v+1,vlen-5);
            v[5]=cached_sps_len>>8; v[6]=cached_sps_len;
            memcpy(v+7,cached_sps,cached_sps_len);
            size_t off=7+cached_sps_len;
            v[off]=cached_pps_len>>8; v[off+1]=cached_pps_len;
            memcpy(v+off+2,cached_pps,cached_pps_len);
            free(cached_v); cached_v=v; cached_v_len=vlen;
            waiting_idr=1;
            if (client>=0) send_packet(cached_v,cached_v_len);
        }
    }
    if (payload==1) goto out;
    if (!cached_v || payload>UINT32_MAX) { clear_gop(); skipped++; goto out; }
    unsigned char *packet=malloc(payload+5);
    if (!packet) { clear_gop(); skipped++; goto out; }
    packet[0]='F'; put32(packet+1,payload); packet[5]=key;
    pos=0; size_t off=6;
    while (next_nal(d->data,n,&pos,&nal,&len)) {
        if (!len || (nal[0]&31)==7 || (nal[0]&31)==8 || (nal[0]&31)==9) continue;
        put32(packet+off,len); off+=4; memcpy(packet+off,nal,len); off+=len;
    }
    cache_frame(packet,off,key);
    if (client<0 || (waiting_idr && !key)) skipped++;
    else if (send_packet(packet,off)<0) skipped++;
    else waiting_idr=0;
    free(packet);
out:
    pthread_mutex_unlock(&videolock);
}
static void *accept_loop(void *unused) {
    (void)unused;
    while (!stopping) {
        pthread_mutex_lock(&videolock);
        if (client>=0) {
            unsigned char byte;
            ssize_t got=recv(client,&byte,1,MSG_PEEK|MSG_DONTWAIT);
            if (!got || (got<0 && errno!=EAGAIN && errno!=EWOULDBLOCK && errno!=EINTR)) disconnect_client();
        }
        if (client>=0) {
            struct timeval now; gettimeofday(&now,NULL);
            if ((double)(now.tv_sec-last_sent.tv_sec)+(now.tv_usec-last_sent.tv_usec)/1000000.0>=1.0) {
                const unsigned char keepalive[5]={'K',0,0,0,0};
                send_packet(keepalive,sizeof keepalive);
            }
        }
        pthread_mutex_unlock(&videolock);
        fd_set rd; FD_ZERO(&rd); FD_SET(listener,&rd);
        struct timeval tv={0,200000};
        if (select(listener+1,&rd,NULL,NULL,&tv)<=0) continue;
        int fd=accept(listener,NULL,NULL);
        if(fd<0) continue;
        int one=1; struct timeval timeout={0,200000};
        if (setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof one) ||
            setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&one,sizeof one) ||
            setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof timeout)) { close(fd); continue; }
        pthread_mutex_lock(&videolock);
        disconnect_client(); client=fd; waiting_idr=1; logline("Araç bağlandı");
        gettimeofday(&last_sent,NULL);
        if(cached_v) send_packet(cached_v,cached_v_len);
        if (client>=0 && cached_gop_frames) {
            struct timeval replay_timeout={2,0};
            if (setsockopt(client,SOL_SOCKET,SO_SNDTIMEO,&replay_timeout,sizeof replay_timeout)) disconnect_client();
            /* Yeniden oynatılan karelerin yalnız sonuncusu gösterilsin (bayrak bit 1);
             * yoksa Araç askıdan dönünce aradaki görüntüyü hızlandırılmış oynatıyor. */
            for (size_t off=0,i=0; off+6<=cached_gop_len; i++) {
                size_t n=((size_t)cached_gop[off+1]<<24)|((size_t)cached_gop[off+2]<<16)|((size_t)cached_gop[off+3]<<8)|cached_gop[off+4];
                if (i+1<cached_gop_frames) cached_gop[off+5]|=2;
                off+=5+n;
            }
            int sent=client>=0 ? send_packet(cached_gop,cached_gop_len) : -1;
            for (size_t off=0; off+6<=cached_gop_len;) {
                size_t n=((size_t)cached_gop[off+1]<<24)|((size_t)cached_gop[off+2]<<16)|((size_t)cached_gop[off+3]<<8)|cached_gop[off+4];
                cached_gop[off+5]&=1;
                off+=5+n;
            }
            if (sent==0) {
                waiting_idr=0;
                logline("GOP yollandı: %zu kare, %zu bayt",cached_gop_frames,cached_gop_len);
            }
            if (client>=0 && setsockopt(client,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof timeout)) disconnect_client();
        }
        pthread_mutex_unlock(&videolock);
    }
    return NULL;
}
static int start_local(void) {
    listener=socket(AF_INET,SOCK_STREAM,0);
    if(listener<0) return -1;
    int one=1; setsockopt(listener,SOL_SOCKET,SO_REUSEADDR,&one,sizeof one);
    struct sockaddr_in addr; memset(&addr,0,sizeof addr);
    addr.sin_family=AF_INET; addr.sin_port=htons(7101); addr.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    if(bind(listener,(struct sockaddr *)&addr,sizeof addr) || listen(listener,4) || listener>=FD_SETSIZE) goto fail;
    if(pthread_create(&accept_thread,NULL,accept_loop,NULL)) goto fail;
    return 0;
fail:
    close(listener); listener=-1; return -1;
}
static int geometry(void *c, video_codec_t codec, unsigned short ws, unsigned short hs, unsigned short x, unsigned short y, unsigned short w, unsigned short h) {
    (void)c; logline("video_set_codec_and_size codec=%s width_source=%u height_source=%u x_offset=%u y_offset=%u width=%u height=%u",codec==VIDEO_CODEC_H264?"H264":codec==VIDEO_CODEC_H265?"H265":"UNKNOWN",ws,hs,x,y,w,h);
    return 0;
}
static void noop(void *c) { (void)c; }
/* Audio state and counters share videolock with the transport. */
#define AUDIO_NODT ((OSStatus)0x6e6f6474)
static AudioConverterRef audio_converter;
static unsigned char audio_ct;
static unsigned cookie_variant;
static int cookie_confirmed, unknown_warned;
static uint64_t audio_packets, audio_decoded, audio_errors, audio_errors_total;
static void audio_dispose(void) {
    if (audio_converter) AudioConverterDispose(audio_converter);
    audio_converter=NULL;
}
static void audio_error(const char *where, OSStatus status) {
    audio_errors++; audio_errors_total++;
    if (audio_errors_total<=5) {
        uint32_t u=(uint32_t)status; char code[5];
        for (int i=0;i<4;i++) { unsigned ch=(u>>(24-8*i))&255; code[i]=ch>=32 && ch<=126?ch:'.'; }
        code[4]=0;
        logline("ses %s ct=%u cookie=%u OSStatus=%"PRId32" ('%s')",where,audio_ct,cookie_variant,(int32_t)status,code);
    }
}
static void audio_restart(unsigned char ct) {
    ses_temizle(); audio_dispose(); audio_ct=ct; cookie_variant=0; cookie_confirmed=0; unknown_warned=0;
}
static const char *cookie_name(void) {
    if (audio_ct==2) return cookie_variant==0?"ALACSpecificConfig (24)":cookie_variant==1?"alac atom (36)":"frma + alac (48)";
    return cookie_variant==0?"raw AudioSpecificConfig":"ES_Descriptor";
}
static OSStatus audio_create(void) {
    AudioStreamBasicDescription in={0}, out={0};
    in.mSampleRate=44100; in.mChannelsPerFrame=2;
    in.mFormatID=audio_ct==2?kAudioFormatAppleLossless:audio_ct==8?kAudioFormatMPEG4AAC_ELD:kAudioFormatMPEG4AAC;
    in.mFramesPerPacket=audio_ct==2?352:audio_ct==8?480:1024;
    if (audio_ct==2) { in.mBitsPerChannel=16; in.mFormatFlags=kAppleLosslessFormatFlag_16BitSourceData; }
    out.mSampleRate=44100; out.mFormatID=kAudioFormatLinearPCM;
    out.mFormatFlags=kAudioFormatFlagIsSignedInteger|kAudioFormatFlagIsPacked;
    out.mBytesPerPacket=out.mBytesPerFrame=4; out.mFramesPerPacket=1;
    out.mChannelsPerFrame=2; out.mBitsPerChannel=16;
    OSStatus rc=AudioConverterNew(&in,&out,&audio_converter);
    if (rc) return rc;
    static const unsigned char alac[36]={
        0,0,0,0x24, 'a','l','a','c', 0,0,0,0,
        0,0,1,0x60, 0,0x10,0x28,0x0a, 0x0e,2,0,0xff,
        0,0,0,0, 0,0,0,0, 0,0,0xac,0x44};
    static const unsigned char eld[]={0xf8,0xe8,0x50,0}, lc[]={0x12,0x10};
    unsigned char wrapped[64]; const unsigned char *cookie; UInt32 len;
    if (audio_ct==2) {
        cookie=alac+(cookie_variant==0?12:0); len=cookie_variant==0?24:36;
        if (cookie_variant==2) {
            const unsigned char frma[12]={0,0,0,12,'f','r','m','a','a','l','a','c'};
            memcpy(wrapped,frma,12); memcpy(wrapped+12,alac,36); cookie=wrapped; len=48;
        }
    } else {
        cookie=audio_ct==8?eld:lc; len=audio_ct==8?4:2;
        if (cookie_variant) {
            /* ES_ID=1, MPEG-4 audio (0x40), audio stream, no SL packetization. */
            unsigned char prefix[]={3,0,0,1,0,4,0,0x40,0x15,0,0,0,0,0,0,0,0,0,0,0,5,0};
            prefix[1]=23+len; prefix[6]=15+len; prefix[21]=len;
            memcpy(wrapped,prefix,sizeof prefix); memcpy(wrapped+sizeof prefix,cookie,len);
            unsigned off=sizeof prefix+len;
            wrapped[off++]=6; wrapped[off++]=1; wrapped[off++]=2;
            cookie=wrapped; len=off;
        }
    }
    rc=AudioConverterSetProperty(audio_converter,kAudioConverterDecompressionMagicCookie,len,cookie);
    if (rc) audio_dispose();
    return rc;
}
typedef struct {
    const void *bytes; UInt32 length; int used;
    AudioStreamPacketDescription packet;
} audio_input;
static OSStatus audio_feed(AudioConverterRef converter, UInt32 *packets,
                           AudioBufferList *buffers, AudioStreamPacketDescription **desc, void *context) {
    (void)converter; audio_input *input=context;
    if (input->used || !*packets) { *packets=0; return AUDIO_NODT; }
    input->used=1; *packets=1;
    buffers->mNumberBuffers=1;
    buffers->mBuffers[0].mNumberChannels=2;
    buffers->mBuffers[0].mData=(void *)input->bytes;
    buffers->mBuffers[0].mDataByteSize=input->length;
    if (desc) *desc=&input->packet;
    return noErr;
}
static void audio(void *c, raop_ntp_t *n, audio_decode_struct *d) {
    (void)c; (void)n;
    pthread_mutex_lock(&videolock);
    audio_packets++;
    if (audio_ct!=d->ct) audio_restart(d->ct);
    if (audio_ct!=2 && audio_ct!=4 && audio_ct!=8) {
        if (!unknown_warned) { logline("ses bilinmeyen ct=%u; atiliyor",audio_ct); unknown_warned=1; }
        goto end;
    }
    if (!d->data || d->data_len<=0) goto end;
    for (;;) {
        OSStatus rc=audio_converter?noErr:audio_create();
        int16_t pcm[4096*2];
        UInt32 count=4096;
        AudioBufferList output={0}; output.mNumberBuffers=1;
        output.mBuffers[0].mNumberChannels=2;
        output.mBuffers[0].mData=pcm;
        output.mBuffers[0].mDataByteSize=sizeof pcm;
        audio_input input={d->data,(UInt32)d->data_len,0,{0,0,(UInt32)d->data_len}};
        if (!rc) rc=AudioConverterFillComplexBuffer(audio_converter,audio_feed,&input,&count,&output,NULL);
        else count=0;
        if (rc && rc!=AUDIO_NODT) {
            audio_error("decode/create",rc);
            audio_dispose();
            unsigned variants=audio_ct==2?3:2;
            if (!cookie_confirmed && cookie_variant+1<variants) { cookie_variant++; continue; }
            goto end;
        }
        if (count && output.mBuffers[0].mDataByteSize) {
            if (!cookie_confirmed) { logline("ses ct=%u cookie=%s calisiyor",audio_ct,cookie_name()); cookie_confirmed=1; }
            audio_decoded++;
            size_t bytes=output.mBuffers[0].mDataByteSize;
            if (bytes>sizeof pcm) goto end;
            ses_yaz(pcm,bytes/4);
        }
        break;
    }
end:
    pthread_mutex_unlock(&videolock);
}
static void reset(void *c, int r) { (void)c;(void)r; }
static void vreset(void *c, reset_type_t r) { (void)c;(void)r; }
static double volume(void *c) { (void)c;return 0.0; }
static void setvolume(void *c, float f) { (void)c;ses_duzey(f); }
static void audio_flush(void *c) { (void)c; pthread_mutex_lock(&videolock); ses_temizle(); if (audio_converter) AudioConverterReset(audio_converter); pthread_mutex_unlock(&videolock); }
static void video_value(void *c, float f) { (void)c;(void)f; }
static void metadata(void *c,const void *p,int n) { (void)c;(void)p;(void)n; }
static void remote(void *c,const char *a,const char *b) { (void)c;(void)a;(void)b; }
static void progress(void *c,uint32_t *a,uint32_t *b,uint32_t *d) { (void)c;(void)a;(void)b;(void)d; }
static void format(void *c,unsigned char *ct,unsigned short *spf,bool *screen,bool *media,uint64_t *af) {
    (void)c; pthread_mutex_lock(&videolock);
    logline("ses SETUP ct=%u spf=%u usingScreen=%d isMedia=%d audioFormat=0x%016"PRIx64,*ct,*spf,*screen,*media,*af);
    audio_restart(*ct); pthread_mutex_unlock(&videolock);
}
static void running(void *c,bool b) { (void)c;logline("mirror %s",b?"başladı":"bitti"); if (b) logline("Araç acma is parcacigi: %d",uygulama_ac()); }
static void admit(void *c,char *id,char *model,char *name,bool *ok) { (void)c;*ok=true;logline("iPhone bağlandı id=%s model=%s name=%s",id?id:"",model?model:"",name?name:""); }
static void pin(void *c,char *p) { (void)c;(void)p; }
static void regclient(void *c,const char *id,const char *pk,const char *name) { (void)c;(void)id;(void)pk;(void)name; }
static bool registered(void *c,const char *pk) { (void)c;(void)pk;return true; }
static void play(void *c,const char *url,float f) { (void)c;(void)url;(void)f; }
static void info(void *c,playback_info_t *p) { (void)c;memset(p,0,sizeof *p); }
static float removeplaylist(void *c) { (void)c;return 0; }
static void custom(void *c,const char **p) { (void)c;*p=NULL; }
int main(int argc,char **argv) {
    int w=1024,h=768,debug=0,opt; char tail;
    while ((opt=getopt(argc,argv,"s:d"))!=-1) {
        if (opt=='d') debug=1;
        else if (opt=='s' && sscanf(optarg,"%dx%d%c",&w,&h,&tail)==2 && w>0 && w<=65535 && h>0 && h<=65535) {}
        else { fprintf(stderr,"Kullanim: %s [-s WxH] [-d]\n",argv[0]);return 2; }
    }
    if (optind!=argc) return 2;
    if (drop_root()) { fprintf(stderr,"mobile kullanicisina inilemedi: %s\n",strerror(errno));return 1; }
    mkdir("/var/mobile/Library/Logs",0755);
    struct stat st;
    const char *mode=stat("/var/mobile/Library/Logs/arac-airplay.log",&st)==0 && st.st_size>512*1024?"w":"a";
    logfile=fopen("/var/mobile/Library/Logs/arac-airplay.log",mode);
    if (!logfile) { fprintf(stderr,"Gunluk acilamadi: %s\n",strerror(errno));return 1; }
    struct sigaction sa; memset(&sa,0,sizeof sa);sa.sa_handler=caught;sigemptyset(&sa.sa_mask);
    sigaction(SIGINT,&sa,NULL);sigaction(SIGTERM,&sa,NULL);signal(SIGPIPE,SIG_IGN);
    int fatal[]={SIGSEGV,SIGBUS,SIGABRT,SIGILL,SIGFPE};
    for (size_t i=0;i<sizeof fatal/sizeof *fatal;i++) signal(fatal[i],crashed);
    atexit(exited);
    logline("jetsam oncelik=%d sinir=%d uid=%d",jetsam_rc[0],jetsam_rc[1],(int)getuid());
    if (ses_baslat()) logline("Yerel ses baslatilamadi; goruntu devam ediyor");
    debug_logs=debug;
    int local_started=0;
    int result=1,error=0,raop_registered=0,airplay_registered=0;
    const char name[]="Araç Ekran", mac[]={0x02,(char)0xA5,0x1C,0x0D,(char)0xEC,0x01};
    dnssd_t *dns=dnssd_init(name,(int)strlen(name),mac,6,0,&error);
    raop_t *raop=NULL;
    if (!dns || error) { logline("dnssd_init error=%d",error);goto done; }
    for (int bit=0;bit<64;bit++) dnssd_set_airplay_features(dns,bit,bit<32?(int)((UINT64_C(0x5A7FFEE6)>>bit)&1):0);
    dnssd_set_airplay_features(dns,42,0);
    raop_callbacks_t cb={0};
    cb.audio_process=audio;cb.video_process=video;cb.video_pause=noop;cb.video_resume=noop;
    cb.conn_feedback=noop;cb.conn_reset=reset;cb.video_reset=vreset;cb.video_set_codec_and_size=geometry;
    cb.conn_init=noop;cb.conn_destroy=noop;cb.audio_flush=audio_flush;cb.video_flush=noop;
    cb.audio_set_client_volume=volume;cb.audio_set_volume=setvolume;cb.audio_set_metadata=metadata;
    cb.audio_set_coverart=metadata;cb.audio_stop_coverart_rendering=noop;cb.audio_remote_control_id=remote;
    cb.audio_set_progress=progress;cb.audio_get_format=format;cb.mirror_video_running=running;
    cb.report_client_request=admit;cb.display_pin=pin;cb.register_client=regclient;cb.check_register=registered;
    cb.passwd=NULL;cb.export_dacp=remote;cb.on_video_play=play;cb.on_video_scrub=video_value;
    cb.on_video_rate=video_value;cb.on_video_stop=noop;cb.on_video_acquire_playback_info=info;
    cb.on_video_playlist_remove=removeplaylist;cb.get_custom_profile=custom;
    if(start_local()) { logline("Yerel sunucu: %s",strerror(errno)); goto done; }
    local_started=1;
    ntp_global_init();
    raop=raop_init(&cb);
    if (!raop) { logline("raop_init basarisiz");goto done; }
    raop_set_log_callback(raop,library_log,NULL);raop_set_log_level(raop,debug?LOGGER_DEBUG:LOGGER_INFO);
    if (raop_init2(raop,1,"02:A5:1C:0D:EC:01","/var/mobile/Library/arac-airplay-key.pem")) { logline("raop_init2 basarisiz"); /* UxPlay also frees the incomplete instance here. */ free(raop);raop=NULL;goto done; }
    raop_set_plist(raop,"width",w);raop_set_plist(raop,"height",h);
    raop_set_plist(raop,"maxFPS",30);raop_set_plist(raop,"refreshRate",30);raop_set_plist(raop,"hls",0);
    unsigned short port=7100;
    raop_set_port(raop,port);
    if (raop_start_httpd(raop,&port)<0 || port!=7100) { logline("HTTP baslatilamadi port=%u",port);goto done; }
    raop_set_port(raop,port);raop_set_dnssd(raop,dns);
    error=dnssd_register_raop(dns,port);
    if (error) { logline("RAOP Bonjour error=%d",error);goto done; } raop_registered=1;
    error=dnssd_register_airplay(dns,port);
    if (error) { logline("AirPlay Bonjour error=%d",error);goto done; } airplay_registered=1;
    logline("Araç Ekran hazir port=%u ilan=%dx%d maxFPS=30 refreshRate=30 features=0x%016"PRIx64" HLS=0 MultiCodec=0",port,w,h,dnssd_get_airplay_features(dns));
    result=0;
    time_t summary=time(NULL);
    while (!stopping) {
        time_t now=time(NULL);
        if(now-summary>=30) {
            pthread_mutex_lock(&videolock);
            logline("son 30 sn: %"PRIu64" kare, %"PRIu64" anahtar, %"PRIu64" atlanan, önbellek %zu kare/%zu bayt",frames,keyframes,skipped,cached_gop_frames,cached_gop_len);
            logline("son 30 sn ses: paket=%"PRIu64" cozulen=%"PRIu64" hata=%"PRIu64,audio_packets,audio_decoded,audio_errors);
            audio_packets=audio_decoded=audio_errors=0;
            frames=skipped=keyframes=0; pthread_mutex_unlock(&videolock); summary=now;
        }
        fd_set fds;FD_ZERO(&fds);int maxfd=-1,fd[2];
        for (int i=0;i<2;i++) { fd[i]=dnssd_get_service_fd(dns,i);if (fd[i]>=0 && fd[i]<FD_SETSIZE) { FD_SET(fd[i],&fds);if(fd[i]>maxfd) maxfd=fd[i]; } }
        struct timeval timeout={1,0};int rc=select(maxfd+1,&fds,NULL,NULL,&timeout);
        if(rc<0 && errno!=EINTR) { logline("select: %s",strerror(errno));result=1;break; }
        if(rc>0) for(int i=0;i<2;i++) if(fd[i]>=0 && fd[i]<FD_SETSIZE && FD_ISSET(fd[i],&fds)) {
            int e=dnssd_process_service(dns,i);if(e) { logline("Bonjour service=%d error=%d",i,e);stopping=1;result=1; }
        }
    }
done:
    stopping=1;
    if(local_started) { pthread_join(accept_thread,NULL); close(listener); }
    if(airplay_registered) dnssd_unregister_airplay(dns);
    if(raop_registered) dnssd_unregister_raop(dns);
    if(raop) { raop_stop_httpd(raop);raop_destroy(raop); }
    audio_dispose();
    ses_kapat();
    if(dns) dnssd_destroy(dns);
    disconnect_client();
    clear_gop();
    free(cached_sps); free(cached_pps); free(cached_v); free(last_sps);
    logline("Kapandi");
    pthread_mutex_lock(&loglock);
    fclose(logfile); logfile=NULL;
    pthread_mutex_unlock(&loglock);
    return result;
}
