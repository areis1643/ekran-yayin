#ifndef ARACAIRPLAY_IOS_H
#define ARACAIRPLAY_IOS_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
int ses_baslat(void);
/* zaman: ilk örneğin duyulması gereken CLOCK_REALTIME ns; 0 = hemen çal. */
void ses_yaz(const int16_t *pcm, size_t kare, uint64_t zaman);
void ses_temizle(void);
/* Çıkışın (Bluetooth dahil) ek gecikmesi, ns. */
int64_t ses_cikis_gecikmesi(void);
/* Geç gelip atılan ve erken gelip sessizlikle beklenen örnek sayıları; okuyunca sıfırlanır. */
void ses_sayaclar(uint64_t *atilan, uint64_t *beklenen);
/* Etkin ses çıkışının adı ve gecikmesi günlüğe yazılır. */
void ses_rota_yaz(void);
void ses_duzey(float db);
void ses_kapat(void);
/* Returns dispatch status; the asynchronous SBS result is logged by the worker. */
int uygulama_ac(void);
#ifdef __cplusplus
}
#endif
#endif
