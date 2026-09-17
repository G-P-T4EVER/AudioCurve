/*
 * ACShared.h - shared contract between the mediaserverd hook, the SpringBoard
 * relay and the AudioCurve app. Pure C so it can be included from .c, .m and .xm.
 *
 * Two uint64 notify states carry everything, so no sandbox-crossing file IO or
 * IPC server is required:
 *
 *   AC_KEY_SETTINGS : app / SpringBoard  ->  mediaserverd   (enable + 3 gains)
 *   AC_KEY_LEVELS   : mediaserverd       ->  app            (8 band magnitudes)
 */

#ifndef AC_SHARED_H
#define AC_SHARED_H

#include <math.h>
#include <stdint.h>

#define AC_BUNDLE_ID "com.sa1nt.audiocurve"
#define AC_PREFS_PATH "/var/mobile/Library/Preferences/com.sa1nt.audiocurve.plist"

#define AC_KEY_SETTINGS "com.sa1nt.audiocurve.settings"
#define AC_KEY_LEVELS "com.sa1nt.audiocurve.levels"

#define AC_NOTE_PREFS_CHANGED "com.sa1nt.audiocurve/prefschanged"
#define AC_NOTE_RELAY_SYNC "com.sa1nt.audiocurve/relaysync"

/* Gain range exposed in the UI, in dB. */
#define AC_GAIN_MIN (-12.0f)
#define AC_GAIN_MAX (12.0f)

/* Which unit role in the mediaserverd audio graph gets processed. */
enum {
	ACTargetAuto = 0, /* output unit if one is seen, otherwise the mixer */
	ACTargetMixer = 1,
	ACTargetOutput = 2,
	ACTargetAll = 3
};

/* EQ curve modes shown in the UI. */
enum { ACModeRecommended = 0, ACModeCustom = 1 };

/*
 * Settings packing (uint64):
 *   bit  0      : payload valid
 *   bit  1      : enabled
 *   bit  2      : mode (0 recommended / 1 custom)
 *   bits 8-15   : low  gain, int8, quarter-dB steps
 *   bits 16-23  : mid  gain, int8, quarter-dB steps
 *   bits 24-31  : high gain, int8, quarter-dB steps
 *   bits 32-39  : serial, bumped on every publish so identical values re-apply
 */
#define AC_SETTINGS_VALID (1ULL << 0)

static inline int8_t ac_db_to_q(float db)
{
	float q = db * 4.0f;
	if (q > 127.0f) q = 127.0f;
	if (q < -127.0f) q = -127.0f;
	return (int8_t)(q >= 0.0f ? (q + 0.5f) : (q - 0.5f));
}

static inline float ac_q_to_db(int8_t q) { return (float)q * 0.25f; }

static inline uint64_t ac_pack_settings(int enabled, int mode, float lowDb,
					float midDb, float highDb, uint8_t serial)
{
	uint64_t v = AC_SETTINGS_VALID;
	if (enabled) v |= (1ULL << 1);
	if (mode == ACModeCustom) v |= (1ULL << 2);
	v |= ((uint64_t)(uint8_t)ac_db_to_q(lowDb)) << 8;
	v |= ((uint64_t)(uint8_t)ac_db_to_q(midDb)) << 16;
	v |= ((uint64_t)(uint8_t)ac_db_to_q(highDb)) << 24;
	v |= ((uint64_t)serial) << 32;
	return v;
}

static inline void ac_unpack_settings(uint64_t v, int *enabled, int *mode,
				      float *lowDb, float *midDb, float *highDb)
{
	if (enabled) *enabled = (v & (1ULL << 1)) ? 1 : 0;
	if (mode) *mode = (v & (1ULL << 2)) ? ACModeCustom : ACModeRecommended;
	if (lowDb) *lowDb = ac_q_to_db((int8_t)((v >> 8) & 0xFF));
	if (midDb) *midDb = ac_q_to_db((int8_t)((v >> 16) & 0xFF));
	if (highDb) *highDb = ac_q_to_db((int8_t)((v >> 24) & 0xFF));
}

/*
 * Levels packing (uint64): 8 bands x 8 bits, band 0 is the lowest.
 * 0 maps to -60 dBFS or quieter, 255 maps to 0 dBFS.
 */
static inline uint8_t ac_level_encode(float dbfs)
{
	float n = (dbfs + 60.0f) / 60.0f;
	if (n <= 0.0f) return 0;
	if (n >= 1.0f) return 255;
	return (uint8_t)(n * 255.0f + 0.5f);
}

static inline float ac_level_decode(uint8_t raw) { return (float)raw / 255.0f; }

#endif /* AC_SHARED_H */
