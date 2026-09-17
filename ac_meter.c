#include "ac_meter.h"

#include "ACShared.h"

#include <math.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static const float kCenters[AC_METER_BANDS] = { 60.0f,   120.0f,  250.0f,
						500.0f,  1000.0f, 2000.0f,
						4000.0f, 8000.0f };

#define AC_METER_Q 1.4f

static void ac_bandpass(ac_coeffs *c, float fs, float f0, float Q)
{
	const float nyquist = fs * 0.5f;
	if (f0 > nyquist * 0.9f) f0 = nyquist * 0.9f;

	const float w0 = 2.0f * (float)M_PI * (f0 / fs);
	const float alpha = sinf(w0) / (2.0f * Q);
	const float a0 = 1.0f + alpha;

	/* Constant 0 dB peak gain bandpass. */
	c->b0 = alpha / a0;
	c->b1 = 0.0f;
	c->b2 = -alpha / a0;
	c->a1 = (-2.0f * cosf(w0)) / a0;
	c->a2 = (1.0f - alpha) / a0;
}

void ac_meter_init(ac_meter *m, float sampleRate)
{
	memset(m, 0, sizeof(*m));
	m->sampleRate = (sampleRate > 8000.0f) ? sampleRate : 44100.0f;
	ac_meter_set_sample_rate(m, m->sampleRate);
}

void ac_meter_set_sample_rate(ac_meter *m, float sampleRate)
{
	if (sampleRate < 8000.0f || sampleRate > 768000.0f) return;

	m->sampleRate = sampleRate;
	memset(m->s, 0, sizeof(m->s));

	for (int b = 0; b < AC_METER_BANDS; b++)
		ac_bandpass(&m->c[b], sampleRate, kCenters[b], AC_METER_Q);

	/* 12 ms attack, 220 ms release. */
	m->attack = 1.0f - expf(-1.0f / (0.012f * sampleRate));
	m->release = 1.0f - expf(-1.0f / (0.220f * sampleRate));
}

void ac_meter_process(ac_meter *m, const float *mono, uint32_t frames)
{
	if (!mono || frames == 0) return;

	for (int b = 0; b < AC_METER_BANDS; b++) {
		const ac_coeffs c = m->c[b];
		ac_state *st = &m->s[b];
		float x1 = st->x1, x2 = st->x2, y1 = st->y1, y2 = st->y2;
		float env = m->env[b];

		for (uint32_t i = 0; i < frames; i++) {
			const float x = mono[i];
			const float y = c.b0 * x + c.b1 * x1 + c.b2 * x2 -
					c.a1 * y1 - c.a2 * y2;
			x2 = x1;
			x1 = x;
			y2 = y1;
			y1 = y;

			const float a = fabsf(y);
			env += (a - env) * (a > env ? m->attack : m->release);
		}

		if (!isfinite(env)) env = 0.0f;
		if (!isfinite(y1) || !isfinite(y2)) {
			x1 = x2 = y1 = y2 = 0.0f;
		}

		st->x1 = x1;
		st->x2 = x2;
		st->y1 = y1;
		st->y2 = y2;
		m->env[b] = env;
	}
}

void ac_meter_decay(ac_meter *m, float factor)
{
	if (factor < 0.0f) factor = 0.0f;
	if (factor > 1.0f) factor = 1.0f;
	for (int b = 0; b < AC_METER_BANDS; b++) m->env[b] *= factor;
}

uint64_t ac_meter_pack(const ac_meter *m)
{
	uint64_t packed = 0;

	for (int b = 0; b < AC_METER_BANDS; b++) {
		const float env = m->env[b];
		const float db = 20.0f * log10f(env > 1e-7f ? env : 1e-7f);
		packed |= ((uint64_t)ac_level_encode(db)) << (b * 8);
	}

	return packed;
}

float ac_meter_center(int band)
{
	if (band < 0) band = 0;
	if (band >= AC_METER_BANDS) band = AC_METER_BANDS - 1;
	return kCenters[band];
}
