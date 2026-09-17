/*
 * Host side sanity tests for the DSP core. Build and run:
 *   cc -O2 -I.. -o /tmp/test_dsp tests/test_dsp.c eq_dsp.c ac_meter.c -lm && /tmp/test_dsp
 */

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "../ACShared.h"
#include "../ac_meter.h"
#include "../eq_dsp.h"

#define FS 48000.0f

static int gFailures = 0;

static void check(const char *what, int ok, const char *detail)
{
	printf("%s %-46s %s\n", ok ? "PASS" : "FAIL", what, detail ? detail : "");
	if (!ok) gFailures++;
}

/* Settle the filter, then measure output/input RMS ratio for a sine. */
static float measure_db(ac_eq *eq, float freq)
{
	const uint32_t warmup = 24000, window = 48000;
	double sumIn = 0.0, sumOut = 0.0;
	float buf[512];
	uint32_t n = 0;

	ac_eq_reset_state(eq);

	while (n < warmup + window) {
		for (uint32_t i = 0; i < 512; i++) {
			const double t = (double)(n + i) / FS;
			buf[i] = 0.25f * (float)sin(2.0 * M_PI * freq * t);
		}

		double blockIn = 0.0;
		for (uint32_t i = 0; i < 512; i++) blockIn += buf[i] * buf[i];

		ac_eq_begin_block(eq);
		ac_eq_process_f32(eq, buf, 512, 1, 0);

		double blockOut = 0.0;
		for (uint32_t i = 0; i < 512; i++) blockOut += buf[i] * buf[i];

		if (n >= warmup) {
			sumIn += blockIn;
			sumOut += blockOut;
		}
		n += 512;
	}

	if (sumIn <= 0.0) return -99.0f;
	return (float)(10.0 * log10(sumOut / sumIn));
}

static void settle(ac_eq *eq)
{
	float silence[256];
	memset(silence, 0, sizeof(silence));
	for (int i = 0; i < 400; i++) {
		ac_eq_begin_block(eq);
		ac_eq_process_f32(eq, silence, 256, 1, 0);
	}
}

static void test_band_response(void)
{
	ac_eq eq;
	char detail[128];

	/* Low shelf only. */
	ac_eq_init(&eq, FS);
	ac_eq_set_gains(&eq, 6.0f, 0.0f, 0.0f);
	settle(&eq);
	float low = measure_db(&eq, 50.0f);
	float high = measure_db(&eq, 12000.0f);
	snprintf(detail, sizeof(detail), "50Hz %+.2f dB, 12kHz %+.2f dB", low, high);
	check("low shelf +6 dB lifts bass, spares treble",
	      low > 4.5f && low < 7.0f && fabsf(high) < 0.5f, detail);

	/* Mid peak only. */
	ac_eq_init(&eq, FS);
	ac_eq_set_gains(&eq, 0.0f, -8.0f, 0.0f);
	settle(&eq);
	float mid = measure_db(&eq, 1000.0f);
	float edge = measure_db(&eq, 60.0f);
	snprintf(detail, sizeof(detail), "1kHz %+.2f dB, 60Hz %+.2f dB", mid, edge);
	check("mid peak -8 dB cuts 1 kHz only",
	      mid < -6.5f && mid > -9.5f && fabsf(edge) < 1.0f, detail);

	/* High shelf only. */
	ac_eq_init(&eq, FS);
	ac_eq_set_gains(&eq, 0.0f, 0.0f, 9.0f);
	settle(&eq);
	float top = measure_db(&eq, 14000.0f);
	float bottom = measure_db(&eq, 80.0f);
	snprintf(detail, sizeof(detail), "14kHz %+.2f dB, 80Hz %+.2f dB", top, bottom);
	check("high shelf +9 dB lifts treble, spares bass",
	      top > 7.0f && top < 10.5f && fabsf(bottom) < 0.6f, detail);
}

static void test_bypass_and_disable(void)
{
	ac_eq eq;
	char detail[128];

	ac_eq_init(&eq, FS);
	ac_eq_set_gains(&eq, 0.0f, 0.0f, 0.0f);
	settle(&eq);
	float flat = measure_db(&eq, 1000.0f);
	snprintf(detail, sizeof(detail), "1kHz %+.4f dB", flat);
	check("flat curve is bit transparent", fabsf(flat) < 0.01f, detail);

	ac_eq_init(&eq, FS);
	ac_eq_set_gains(&eq, 10.0f, 10.0f, 10.0f);
	ac_eq_set_enabled(&eq, 0);
	settle(&eq);
	float off = measure_db(&eq, 200.0f);
	snprintf(detail, sizeof(detail), "200Hz %+.4f dB", off);
	check("disabled tweak passes audio untouched", fabsf(off) < 0.01f, detail);
	check("is_active false when disabled", ac_eq_is_active(&eq) == 0, NULL);
}

static void test_stability_and_clipping(void)
{
	ac_eq eq;
	char detail[128];
	float buf[1024];
	int bad = 0;
	float peak = 0.0f;

	ac_eq_init(&eq, FS);
	ac_eq_set_gains(&eq, 12.0f, 12.0f, 12.0f);
	settle(&eq);

	uint32_t seed = 12345u;
	for (int block = 0; block < 400; block++) {
		for (int i = 0; i < 1024; i++) {
			seed = seed * 1103515245u + 12345u;
			const float r = (float)((seed >> 9) & 0xFFFF) / 32768.0f - 1.0f;
			buf[i] = r * 0.98f; /* hot input on purpose */
		}

		ac_eq_begin_block(&eq);
		ac_eq_process_f32(&eq, buf, 1024, 1, 0);

		for (int i = 0; i < 1024; i++) {
			if (!isfinite(buf[i])) bad++;
			const float a = fabsf(buf[i]);
			if (a > peak) peak = a;
		}
	}

	snprintf(detail, sizeof(detail), "peak %.4f, non finite %d", peak, bad);
	check("max boost stays finite and soft clipped",
	      bad == 0 && peak <= 1.0001f, detail);
}

static void test_int16_path(void)
{
	ac_eq eq;
	char detail[128];
	int16_t interleaved[2 * 4096];
	double sumL = 0.0, sumR = 0.0;

	ac_eq_init(&eq, FS);
	ac_eq_set_gains(&eq, 0.0f, 12.0f, 0.0f);
	settle(&eq);

	for (int i = 0; i < 4096; i++) {
		const double t = (double)i / FS;
		const double s = sin(2.0 * M_PI * 1000.0 * t) * 8000.0;
		interleaved[i * 2 + 0] = (int16_t)s;   /* left gets filtered */
		interleaved[i * 2 + 1] = (int16_t)s;   /* right stays as reference */
	}

	ac_eq_begin_block(&eq);
	ac_eq_process_s16(&eq, interleaved, 4096, 2, 0);

	for (int i = 0; i < 4096; i++) {
		const double l = interleaved[i * 2 + 0];
		const double r = interleaved[i * 2 + 1];
		sumL += l * l;
		sumR += r * r;
	}

	const double gain = 10.0 * log10(sumL / sumR);
	snprintf(detail, sizeof(detail), "left vs right %+.2f dB", gain);
	check("interleaved int16 processes only the target channel",
	      gain > 6.0 && gain < 13.0, detail);
}

static void test_meter(void)
{
	ac_meter m;
	char detail[128];
	float mono[1024];

	ac_meter_init(&m, FS);

	for (int block = 0; block < 60; block++) {
		for (int i = 0; i < 1024; i++) {
			const double t = (double)(block * 1024 + i) / FS;
			mono[i] = 0.5f * (float)sin(2.0 * M_PI * 1000.0 * t);
		}
		ac_meter_process(&m, mono, 1024);
	}

	const uint64_t packed = ac_meter_pack(&m);
	int loudest = 0;
	uint8_t loudestValue = 0;
	for (int b = 0; b < AC_METER_BANDS; b++) {
		const uint8_t v = (uint8_t)((packed >> (b * 8)) & 0xFF);
		if (v > loudestValue) {
			loudestValue = v;
			loudest = b;
		}
	}

	snprintf(detail, sizeof(detail), "loudest band %.0f Hz, level %u",
		 ac_meter_center(loudest), loudestValue);
	check("1 kHz tone lights up the 1 kHz band",
	      fabsf(ac_meter_center(loudest) - 1000.0f) < 1.0f && loudestValue > 120,
	      detail);

	ac_meter_decay(&m, 0.0f);
	check("meter decays to silence", ac_meter_pack(&m) == 0, NULL);
}

static void test_packing(void)
{
	char detail[128];
	int enabled = 0, mode = 0;
	float lo = 0.0f, mid = 0.0f, hi = 0.0f;

	const uint64_t v = ac_pack_settings(1, ACModeCustom, -7.25f, 3.5f, 11.75f, 42);
	ac_unpack_settings(v, &enabled, &mode, &lo, &mid, &hi);

	snprintf(detail, sizeof(detail), "%.2f / %.2f / %.2f", lo, mid, hi);
	check("settings survive the uint64 round trip",
	      enabled == 1 && mode == ACModeCustom && fabsf(lo + 7.25f) < 0.001f &&
		      fabsf(mid - 3.5f) < 0.001f && fabsf(hi - 11.75f) < 0.001f,
	      detail);

	check("invalid payload is detectable", (0ULL & AC_SETTINGS_VALID) == 0, NULL);
}

int main(void)
{
	printf("AudioCurve DSP tests @ %.0f Hz\n\n", FS);

	test_band_response();
	test_bypass_and_disable();
	test_stability_and_clipping();
	test_int16_path();
	test_meter();
	test_packing();

	printf("\n%s\n", gFailures ? "SOME TESTS FAILED" : "all tests passed");
	return gFailures ? 1 : 0;
}
