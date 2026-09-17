/*
 * ac_meter.h - cheap 8 band magnitude analyser that feeds the waveform in the UI.
 *
 * Runs on a mono downmix inside the mediaserverd render thread, so it is
 * allocation free and uses only one biquad plus one envelope per band.
 */

#ifndef AC_METER_H
#define AC_METER_H

#include <stdint.h>

#include "eq_dsp.h"

#ifdef __cplusplus
extern "C" {
#endif

#define AC_METER_BANDS 8

typedef struct {
	ac_coeffs c[AC_METER_BANDS];
	ac_state s[AC_METER_BANDS];
	float env[AC_METER_BANDS];
	float attack;
	float release;
	float sampleRate;
} ac_meter;

void ac_meter_init(ac_meter *m, float sampleRate);
void ac_meter_set_sample_rate(ac_meter *m, float sampleRate);
void ac_meter_process(ac_meter *m, const float *mono, uint32_t frames);
void ac_meter_decay(ac_meter *m, float factor);

/* Packs the 8 envelopes into one uint64 for notify_set_state. */
uint64_t ac_meter_pack(const ac_meter *m);

/* Center frequency of a band, for the UI mapping. */
float ac_meter_center(int band);

#ifdef __cplusplus
}
#endif

#endif /* AC_METER_H */
