#include "eq_dsp.h"

#include <math.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* Max gain change per render block, keeps knob drags click free. */
#define AC_SMOOTH_STEP_DB 0.35f
#define AC_GAIN_EPSILON 0.02f

static const float kFreq[AC_BANDS] = { 110.0f, 1000.0f, 6500.0f };
static const float kQ[AC_BANDS] = { 0.9f, 0.85f, 0.9f };

static void ac_set_bypass(ac_coeffs *c)
{
	c->b0 = 1.0f;
	c->b1 = c->b2 = c->a1 = c->a2 = 0.0f;
}

static void ac_normalize(ac_coeffs *c, float b0, float b1, float b2, float a0,
			 float a1, float a2)
{
	if (a0 == 0.0f || !isfinite(a0)) {
		ac_set_bypass(c);
		return;
	}
	const float inv = 1.0f / a0;
	c->b0 = b0 * inv;
	c->b1 = b1 * inv;
	c->b2 = b2 * inv;
	c->a1 = a1 * inv;
	c->a2 = a2 * inv;
}

static void ac_low_shelf(ac_coeffs *c, float fs, float f0, float dB, float S)
{
	const float A = powf(10.0f, dB / 40.0f);
	const float w0 = 2.0f * (float)M_PI * (f0 / fs);
	const float cw = cosf(w0);
	const float sw = sinf(w0);
	const float alpha =
		sw * 0.5f * sqrtf((A + 1.0f / A) * (1.0f / S - 1.0f) + 2.0f);
	const float beta = 2.0f * sqrtf(A) * alpha;

	ac_normalize(c,
		     A * ((A + 1.0f) - (A - 1.0f) * cw + beta),
		     2.0f * A * ((A - 1.0f) - (A + 1.0f) * cw),
		     A * ((A + 1.0f) - (A - 1.0f) * cw - beta),
		     (A + 1.0f) + (A - 1.0f) * cw + beta,
		     -2.0f * ((A - 1.0f) + (A + 1.0f) * cw),
		     (A + 1.0f) + (A - 1.0f) * cw - beta);
}

static void ac_high_shelf(ac_coeffs *c, float fs, float f0, float dB, float S)
{
	const float A = powf(10.0f, dB / 40.0f);
	const float w0 = 2.0f * (float)M_PI * (f0 / fs);
	const float cw = cosf(w0);
	const float sw = sinf(w0);
	const float alpha =
		sw * 0.5f * sqrtf((A + 1.0f / A) * (1.0f / S - 1.0f) + 2.0f);
	const float beta = 2.0f * sqrtf(A) * alpha;

	ac_normalize(c,
		     A * ((A + 1.0f) + (A - 1.0f) * cw + beta),
		     -2.0f * A * ((A - 1.0f) + (A + 1.0f) * cw),
		     A * ((A + 1.0f) + (A - 1.0f) * cw - beta),
		     (A + 1.0f) - (A - 1.0f) * cw + beta,
		     2.0f * ((A - 1.0f) - (A + 1.0f) * cw),
		     (A + 1.0f) - (A - 1.0f) * cw - beta);
}

static void ac_peaking(ac_coeffs *c, float fs, float f0, float dB, float Q)
{
	const float A = powf(10.0f, dB / 40.0f);
	const float w0 = 2.0f * (float)M_PI * (f0 / fs);
	const float cw = cosf(w0);
	const float alpha = sinf(w0) / (2.0f * Q);

	ac_normalize(c, 1.0f + alpha * A, -2.0f * cw, 1.0f - alpha * A,
		     1.0f + alpha / A, -2.0f * cw, 1.0f - alpha / A);
}

static void ac_rebuild(ac_eq *eq)
{
	const float nyquist = eq->sampleRate * 0.5f;

	for (int b = 0; b < AC_BANDS; b++) {
		float f0 = eq->freq[b];
		if (f0 > nyquist * 0.92f) f0 = nyquist * 0.92f;

		if (fabsf(eq->gain[b]) < AC_GAIN_EPSILON) {
			ac_set_bypass(&eq->c[b]);
			eq->active[b] = 0;
			continue;
		}

		eq->active[b] = 1;
		if (b == 0)
			ac_low_shelf(&eq->c[b], eq->sampleRate, f0, eq->gain[b],
				     eq->q[b]);
		else if (b == AC_BANDS - 1)
			ac_high_shelf(&eq->c[b], eq->sampleRate, f0, eq->gain[b],
				      eq->q[b]);
		else
			ac_peaking(&eq->c[b], eq->sampleRate, f0, eq->gain[b],
				   eq->q[b]);
	}

	eq->dirty = 0;
}

void ac_eq_init(ac_eq *eq, float sampleRate)
{
	memset(eq, 0, sizeof(*eq));
	eq->sampleRate = (sampleRate > 8000.0f) ? sampleRate : 44100.0f;
	eq->enabled = 1;
	for (int b = 0; b < AC_BANDS; b++) {
		eq->freq[b] = kFreq[b];
		eq->q[b] = kQ[b];
		ac_set_bypass(&eq->c[b]);
	}
	eq->dirty = 1;
}

void ac_eq_set_sample_rate(ac_eq *eq, float sampleRate)
{
	if (sampleRate < 8000.0f || sampleRate > 768000.0f) return;
	if (fabsf(sampleRate - eq->sampleRate) < 1.0f) return;
	eq->sampleRate = sampleRate;
	eq->dirty = 1;
	ac_eq_reset_state(eq);
}

void ac_eq_set_gains(ac_eq *eq, float lowDb, float midDb, float highDb)
{
	eq->target[0] = lowDb;
	eq->target[1] = midDb;
	eq->target[2] = highDb;
}

void ac_eq_set_enabled(ac_eq *eq, int enabled) { eq->enabled = enabled ? 1 : 0; }

void ac_eq_reset_state(ac_eq *eq)
{
	memset(eq->s, 0, sizeof(eq->s));
}

int ac_eq_is_active(const ac_eq *eq)
{
	if (!eq->enabled) return 0;
	for (int b = 0; b < AC_BANDS; b++) {
		if (fabsf(eq->gain[b]) >= AC_GAIN_EPSILON) return 1;
		if (fabsf(eq->target[b] - eq->gain[b]) >= AC_GAIN_EPSILON) return 1;
	}
	return 0;
}

void ac_eq_begin_block(ac_eq *eq)
{
	int moved = 0;

	for (int b = 0; b < AC_BANDS; b++) {
		float want = eq->enabled ? eq->target[b] : 0.0f;
		float delta = want - eq->gain[b];

		if (fabsf(delta) < 0.001f) {
			if (eq->gain[b] != want) {
				eq->gain[b] = want;
				moved = 1;
			}
			continue;
		}

		if (delta > AC_SMOOTH_STEP_DB) delta = AC_SMOOTH_STEP_DB;
		if (delta < -AC_SMOOTH_STEP_DB) delta = -AC_SMOOTH_STEP_DB;
		eq->gain[b] += delta;
		moved = 1;
	}

	if (moved || eq->dirty) ac_rebuild(eq);
}

static inline float ac_softclip(float v)
{
	const float t = 0.98f;
	if (v > t) return t + (1.0f - t) * (1.0f - 1.0f / (1.0f + (v - t) * 8.0f));
	if (v < -t)
		return -(t + (1.0f - t) * (1.0f - 1.0f / (1.0f + (-v - t) * 8.0f)));
	return v;
}

void ac_eq_process_f32(ac_eq *eq, float *data, uint32_t frames, uint32_t stride,
		       uint32_t channel)
{
	if (!data || frames == 0 || stride == 0 || channel >= AC_MAX_CHANNELS) return;

	int touched = 0;

	for (int b = 0; b < AC_BANDS; b++) {
		if (!eq->active[b]) {
			memset(&eq->s[channel][b], 0, sizeof(ac_state));
			continue;
		}

		const ac_coeffs c = eq->c[b];
		ac_state *st = &eq->s[channel][b];
		float x1 = st->x1, x2 = st->x2, y1 = st->y1, y2 = st->y2;

		for (uint32_t i = 0; i < frames; i++) {
			const float x = data[i * stride];
			const float y = c.b0 * x + c.b1 * x1 + c.b2 * x2 -
					c.a1 * y1 - c.a2 * y2;
			x2 = x1;
			x1 = x;
			y2 = y1;
			y1 = y;
			data[i * stride] = y;
		}

		if (!isfinite(y1) || !isfinite(y2) || !isfinite(x1) || !isfinite(x2)) {
			x1 = x2 = y1 = y2 = 0.0f;
		}

		st->x1 = x1;
		st->x2 = x2;
		st->y1 = y1;
		st->y2 = y2;
		touched = 1;
	}

	if (!touched) return;

	for (uint32_t i = 0; i < frames; i++)
		data[i * stride] = ac_softclip(data[i * stride]);
}

void ac_eq_process_s16(ac_eq *eq, int16_t *data, uint32_t frames,
		       uint32_t stride, uint32_t channel)
{
	if (!data || frames == 0 || stride == 0 || channel >= AC_MAX_CHANNELS) return;

	/* Scratch is small and fixed so the render thread never allocates. */
	enum { kChunk = 512 };
	float scratch[kChunk];

	uint32_t done = 0;
	while (done < frames) {
		uint32_t n = frames - done;
		if (n > kChunk) n = kChunk;

		int16_t *src = data + (size_t)done * stride;
		for (uint32_t i = 0; i < n; i++)
			scratch[i] = (float)src[i * stride] * (1.0f / 32768.0f);

		ac_eq_process_f32(eq, scratch, n, 1, channel);

		for (uint32_t i = 0; i < n; i++) {
			float v = scratch[i] * 32768.0f;
			if (v > 32767.0f) v = 32767.0f;
			if (v < -32768.0f) v = -32768.0f;
			src[i * stride] = (int16_t)(v >= 0.0f ? v + 0.5f : v - 0.5f);
		}

		done += n;
	}
}

float ac_eq_magnitude_db(const ac_eq *eq, float frequency)
{
	const double w = 2.0 * M_PI * (double)frequency / (double)eq->sampleRate;
	double total = 1.0;

	for (int b = 0; b < AC_BANDS; b++) {
		const ac_coeffs *c = &eq->c[b];
		const double cw = cos(w), sw = sin(w);
		const double c2w = cos(2.0 * w), s2w = sin(2.0 * w);

		const double numRe = c->b0 + c->b1 * cw + c->b2 * c2w;
		const double numIm = -(c->b1 * sw + c->b2 * s2w);
		const double denRe = 1.0 + c->a1 * cw + c->a2 * c2w;
		const double denIm = -(c->a1 * sw + c->a2 * s2w);

		const double num = sqrt(numRe * numRe + numIm * numIm);
		const double den = sqrt(denRe * denRe + denIm * denIm);
		if (den > 1e-12) total *= num / den;
	}

	return (float)(20.0 * log10(total > 1e-12 ? total : 1e-12));
}
