/* Measurement-only AirPlay receiver; no decoding, rendering or audio output. */
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
#include "raop.h"
#include "dnssd.h"
#include "stream.h"
#include "logger.h"

static FILE *logfile;
static pthread_mutex_t loglock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t videolock = PTHREAD_MUTEX_INITIALIZER;
static volatile sig_atomic_t stopping;
static uint64_t frames;
static unsigned char *last_sps;
static size_t last_sps_len;
static void logline(const char *fmt, ...) {
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
static void library_log(void *c, int level, const char *msg) { (void)c; logline("UxPlay[%d] %s", level, msg); }
static void caught(int sig) { (void)sig; stopping = 1; }

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
static int startcode(const unsigned char *p, size_t n, size_t i) {
    return i+4<=n && !p[i] && !p[i+1] && !p[i+2] && p[i+3]==1;
}
static void video(void *c, raop_ntp_t *ntp, video_decode_struct *d) {
    (void)c; (void)ntp;
    pthread_mutex_lock(&videolock);
    frames++;
    if (frames==1 || frames%100==0) {
        char hex[97]; size_t k=0;
        for (int i=0; d->data && i<d->data_len && i<32; i++) k+=(size_t)snprintf(hex+k,sizeof(hex)-k,"%02x ",d->data[i]);
        hex[k]=0;
        logline("video frame=%"PRIu64" data_len=%d nal_count=%d is_h265=%d ntp_time_local=%"PRIu64" ntp_time_remote=%"PRIu64" hex32=%s",frames,d->data_len,d->nal_count,d->is_h265,d->ntp_time_local,d->ntp_time_remote,hex);
    }
    size_t n=d->data_len>0 && d->data?(size_t)d->data_len:0;
    for (size_t i=0; i+4<n; i++) if (startcode(d->data,n,i)) {
        size_t begin=i+4, end=begin;
        while (end<n && !startcode(d->data,n,end)) end++;
        unsigned t=(d->data[begin]>>1)&63;
        if (d->is_h265 && (t==32 || t==33)) {
            logline("HEVC ALGILANDI: %s NAL type=%u len=%zu",t==32?"VPS":"SPS",t,end-begin);
        } else if (!d->is_h265 && (d->data[begin]&31)==7) sps(d->data+begin,end-begin);
        i=end-1;
    }
    pthread_mutex_unlock(&videolock);
}
static int geometry(void *c, video_codec_t codec, unsigned short ws, unsigned short hs, unsigned short x, unsigned short y, unsigned short w, unsigned short h) {
    (void)c; logline("video_set_codec_and_size codec=%s width_source=%u height_source=%u x_offset=%u y_offset=%u width=%u height=%u",codec==VIDEO_CODEC_H264?"H264":codec==VIDEO_CODEC_H265?"H265":"UNKNOWN",ws,hs,x,y,w,h);
    if (codec==VIDEO_CODEC_H265) logline("HEVC ALGILANDI");
    return 0;
}
static void noop(void *c) { (void)c; }
static void audio(void *c, raop_ntp_t *n, audio_decode_struct *d) { (void)c;(void)n;(void)d; }
static void reset(void *c, int r) { (void)c;logline("conn_reset reason=%d",r); }
static void vreset(void *c, reset_type_t r) { (void)c;logline("video_reset reason=%d",r); }
static double volume(void *c) { (void)c;return 0.0; }
static void setvolume(void *c, float f) { (void)c;(void)f; }
static void metadata(void *c,const void *p,int n) { (void)c;(void)p;(void)n; }
static void remote(void *c,const char *a,const char *b) { (void)c;(void)a;(void)b; }
static void progress(void *c,uint32_t *a,uint32_t *b,uint32_t *d) { (void)c;(void)a;(void)b;(void)d; }
static void format(void *c,unsigned char *ct,unsigned short *spf,bool *screen,bool *media,uint64_t *af) { (void)c;(void)ct;(void)spf;(void)screen;(void)media;(void)af; }
static void running(void *c,bool b) { (void)c;logline("mirror_video_running=%d",b); }
static void admit(void *c,char *id,char *model,char *name,bool *ok) { (void)c;*ok=true;logline("Client id=%s model=%s name=%s",id?id:"",model?model:"",name?name:""); }
static void pin(void *c,char *p) { (void)c;(void)p; }
static void regclient(void *c,const char *id,const char *pk,const char *name) { (void)c;(void)id;(void)pk;(void)name; }
static bool registered(void *c,const char *pk) { (void)c;(void)pk;return true; }
static void play(void *c,const char *url,float f) { (void)c;(void)url;(void)f; }
static void info(void *c,playback_info_t *p) { (void)c;memset(p,0,sizeof *p); }
static float removeplaylist(void *c) { (void)c;return 0; }
static void custom(void *c,const char **p) { (void)c;*p=NULL; }
int main(int argc,char **argv) {
    int w=1280,h=720,debug=0,opt; char tail;
    while ((opt=getopt(argc,argv,"s:d"))!=-1) {
        if (opt=='d') debug=1;
        else if (opt=='s' && sscanf(optarg,"%dx%d%c",&w,&h,&tail)==2 && w>0 && w<=65535 && h>0 && h<=65535) {}
        else { fprintf(stderr,"Kullanim: %s [-s WxH] [-d]\n",argv[0]);return 2; }
    }
    if (optind!=argc) return 2;
    mkdir("/var/mobile/Library/Logs",0755);
    logfile=fopen("/var/mobile/Library/Logs/arac-airplay.log","a");
    if (!logfile) { fprintf(stderr,"Gunluk acilamadi: %s\n",strerror(errno));return 1; }
    struct sigaction sa; memset(&sa,0,sizeof sa);sa.sa_handler=caught;sigemptyset(&sa.sa_mask);
    sigaction(SIGINT,&sa,NULL);sigaction(SIGTERM,&sa,NULL);signal(SIGPIPE,SIG_IGN);
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
    cb.conn_init=noop;cb.conn_destroy=noop;cb.audio_flush=noop;cb.video_flush=noop;
    cb.audio_set_client_volume=volume;cb.audio_set_volume=setvolume;cb.audio_set_metadata=metadata;
    cb.audio_set_coverart=metadata;cb.audio_stop_coverart_rendering=noop;cb.audio_remote_control_id=remote;
    cb.audio_set_progress=progress;cb.audio_get_format=format;cb.mirror_video_running=running;
    cb.report_client_request=admit;cb.display_pin=pin;cb.register_client=regclient;cb.check_register=registered;
    cb.passwd=NULL;cb.export_dacp=remote;cb.on_video_play=play;cb.on_video_scrub=setvolume;
    cb.on_video_rate=setvolume;cb.on_video_stop=noop;cb.on_video_acquire_playback_info=info;
    cb.on_video_playlist_remove=removeplaylist;cb.get_custom_profile=custom;
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
    while (!stopping) {
        fd_set fds;FD_ZERO(&fds);int maxfd=-1,fd[2];
        for (int i=0;i<2;i++) { fd[i]=dnssd_get_service_fd(dns,i);if (fd[i]>=0 && fd[i]<FD_SETSIZE) { FD_SET(fd[i],&fds);if(fd[i]>maxfd) maxfd=fd[i]; } }
        struct timeval timeout={1,0};int rc=select(maxfd+1,&fds,NULL,NULL,&timeout);
        if(rc<0 && errno!=EINTR) { logline("select: %s",strerror(errno));result=1;break; }
        if(rc>0) for(int i=0;i<2;i++) if(fd[i]>=0 && fd[i]<FD_SETSIZE && FD_ISSET(fd[i],&fds)) {
            int e=dnssd_process_service(dns,i);if(e) { logline("Bonjour service=%d error=%d",i,e);stopping=1;result=1; }
        }
    }
done:
    if(airplay_registered) dnssd_unregister_airplay(dns);
    if(raop_registered) dnssd_unregister_raop(dns);
    if(raop) { raop_stop_httpd(raop);raop_destroy(raop); }
    if(dns) dnssd_destroy(dns);
    free(last_sps);logline("Kapandi; video callback sayisi=%"PRIu64,frames);fclose(logfile);
    return result;
}
