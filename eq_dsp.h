/*
 * eq_dsp.h - realtime-safe 3 band shelving/peaking equalizer.
 *
 * No allocation, no locks, no ObjC: everything here is callable from the
 * mediaserverd render thread.
 */

#ifndef AC_EQ_DSP_H
#define AC_EQ_DSP_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define AC_MAX_CHANNELS 8
#define AC_BANDS 3

typedef struct {
	float b0, b1, b2, a1, a2;
} ac_coeffs;

typedef struct {
	float x1, x2, y1, y2;
} ac_state;

typedef struct {
	ac_coeffs c[AC_BANDS];
	ac_state s[AC_MAX_CHANNELS][AC_BANDS];
	float freq[AC_BANDS];
	float q[AC_BANDS];
	float gain[AC_BANDS];   /* currently applied, dB */
	float target[AC_BANDS]; /* requested, dB */
	int active[AC_BANDS];
	float sampleRate;
	int enabled;
	int dirty;
} ac_eq;

void ac_eq_init(ac_eq *eq, float sampleRate);
void ac_eq_set_sample_rate(ac_eq *eq, float sampleRate);
void ac_eq_set_gains(ac_eq *eq, float lowDb, float midDb, float highDb);
void ac_eq_set_enabled(ac_eq *eq, int enabled);
void ac_eq_reset_state(ac_eq *eq);

/* True when the filter would change the signal at all. */
int ac_eq_is_active(const ac_eq *eq);

/* Call once per render block before the process calls. Ramps gains and
 * recomputes coefficients only when something actually moved. */
void ac_eq_begin_block(ac_eq *eq);

/* stride is in samples: 1 for planar buffers, channel count for interleaved. */
void ac_eq_process_f32(ac_eq *eq, float *data, uint32_t frames, uint32_t stride,
		       uint32_t channel);
void ac_eq_process_s16(ac_eq *eq, int16_t *data, uint32_t frames,
		       uint32_t stride, uint32_t channel);

/* Steady state magnitude of the whole cascade at a frequency, in dB.
 * Used by the test harness and by the UI when it needs the real response. */
float ac_eq_magnitude_db(const ac_eq *eq, float frequency);

#ifdef __cplusplus
}
#endif

#endif /* AC_EQ_DSP_H */
