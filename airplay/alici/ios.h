#ifndef ARACAIRPLAY_IOS_H
#define ARACAIRPLAY_IOS_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
int ses_baslat(void);
void ses_yaz(const int16_t *pcm, size_t kare);
void ses_temizle(void);
void ses_duzey(float db);
void ses_kapat(void);
/* Returns dispatch status; the asynchronous SBS result is logged by the worker. */
int uygulama_ac(void);
#ifdef __cplusplus
}
#endif
#endif
