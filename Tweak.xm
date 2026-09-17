/*
 * AudioCurve - system wide 3 band EQ for jailbroken iOS.
 *
 * The dylib is injected into two processes:
 *
 *   mediaserverd : hooks AudioUnitRender and filters the mixed audio, so every
 *                  app that plays sound through the normal media pipeline
 *                  (Music, Spotify, YouTube, Safari, games) is affected.
 *   SpringBoard  : republishes the saved settings after a respring or reboot,
 *                  because mediaserverd may start before the app ever runs.
 *
 * Nothing in the render path allocates, locks blocking primitives, or touches
 * Objective-C.
 */

#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import <mach/mach_time.h>
#import <notify.h>
#import <os/lock.h>
#import <stdatomic.h>

#import "ACShared.h"
#import "ac_meter.h"
#import "eq_dsp.h"

#define AC_LOG(fmt, ...)                                               \
	do {                                                           \
		if (gVerbose) NSLog(@"[AudioCurve] " fmt, ##__VA_ARGS__); \
	} while (0)

enum { ACRoleUnknown = 0, ACRoleMixer, ACRoleOutput, ACRoleSkip };

typedef struct {
	AudioUnit unit;
	AudioStreamBasicDescription asbd;
	uint8_t role;
	uint8_t inUse;
} ACUnitSlot;

#define AC_UNIT_SLOTS 128

static ACUnitSlot gSlots[AC_UNIT_SLOTS];
static os_unfair_lock gSlotsLock = OS_UNFAIR_LOCK_INIT;

static ac_eq gEq;
static ac_meter gMeter;
static os_unfair_lock gMeterLock = OS_UNFAIR_LOCK_INIT;

static _Atomic uint64_t gPendingSettings = 0;
static uint64_t gAppliedSettings = 0;

static int gSettingsToken = -1;
static int gLevelsToken = -1;
static int gVerbose = 0;
static int gTargetMode = ACTargetAuto;
static _Atomic int gSawOutputUnit = 0;

static uint64_t gLastPublishNanos = 0;
static uint64_t gLastAudioNanos = 0;
static double gTicksToNanos = 1.0;

#pragma mark - Time

static void ACInitClock(void)
{
	mach_timebase_info_data_t info;
	if (mach_timebase_info(&info) == KERN_SUCCESS && info.denom != 0)
		gTicksToNanos = (double)info.numer / (double)info.denom;
}

static inline uint64_t ACNowNanos(void)
{
	return (uint64_t)((double)mach_absolute_time() * gTicksToNanos);
}

#pragma mark - Settings

static uint64_t ACReadSettingsFromDisk(void)
{
	NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@(AC_PREFS_PATH)];
	if (![prefs isKindOfClass:[NSDictionary class]]) return 0;

	id enabledValue = prefs[@"enabled"];
	const int enabled = enabledValue ? [enabledValue boolValue] : 1;
	const int mode = [prefs[@"mode"] intValue];

	float low = 0.0f, mid = 0.0f, high = 0.0f;
	if (mode == ACModeCustom) {
		low = [prefs[@"lowGain"] floatValue];
		mid = [prefs[@"midGain"] floatValue];
		high = [prefs[@"highGain"] floatValue];
	}

	id verbose = prefs[@"verbose"];
	if (verbose) gVerbose = [verbose boolValue];

	id target = prefs[@"targetMode"];
	if (target) {
		const int value = [target intValue];
		if (value >= ACTargetAuto && value <= ACTargetAll) gTargetMode = value;
	}

	return ac_pack_settings(enabled, mode, low, mid, high, 0);
}

static void ACApplyPacked(uint64_t packed)
{
	if (!(packed & AC_SETTINGS_VALID)) return;

	int enabled = 1, mode = ACModeRecommended;
	float low = 0.0f, mid = 0.0f, high = 0.0f;
	ac_unpack_settings(packed, &enabled, &mode, &low, &mid, &high);

	if (mode == ACModeRecommended) {
		low = mid = high = 0.0f;
	}

	ac_eq_set_enabled(&gEq, enabled);
	ac_eq_set_gains(&gEq, low, mid, high);
}

static void ACPullSettings(void)
{
	if (gSettingsToken < 0) return;

	uint64_t state = 0;
	if (notify_get_state(gSettingsToken, &state) != NOTIFY_STATUS_OK) return;
	if (!(state & AC_SETTINGS_VALID)) return;

	atomic_store_explicit(&gPendingSettings, state, memory_order_relaxed);
}

#pragma mark - Unit bookkeeping

static uint8_t ACRoleForUnit(AudioUnit unit)
{
	AudioComponent component = AudioComponentInstanceGetComponent(unit);
	if (!component) return ACRoleSkip;

	AudioComponentDescription desc;
	memset(&desc, 0, sizeof(desc));
	if (AudioComponentGetDescription(component, &desc) != noErr) return ACRoleSkip;

	if (desc.componentType == kAudioUnitType_Output) {
		atomic_store_explicit(&gSawOutputUnit, 1, memory_order_relaxed);
		AC_LOG(@"output unit %p subtype %.4s", unit, (char *)&desc.componentSubType);
		return ACRoleOutput;
	}

	if (desc.componentType == kAudioUnitType_Mixer) {
		AC_LOG(@"mixer unit %p subtype %.4s", unit, (char *)&desc.componentSubType);
		return ACRoleMixer;
	}

	AC_LOG(@"ignoring unit %p type %.4s subtype %.4s", unit,
	       (char *)&desc.componentType, (char *)&desc.componentSubType);
	return ACRoleSkip;
}

static ACUnitSlot *ACSlotForUnit(AudioUnit unit, UInt32 bus)
{
	const size_t base = ((uintptr_t)unit >> 4) % AC_UNIT_SLOTS;
	ACUnitSlot *result = NULL;

	os_unfair_lock_lock(&gSlotsLock);

	for (size_t probe = 0; probe < AC_UNIT_SLOTS; probe++) {
		ACUnitSlot *slot = &gSlots[(base + probe) % AC_UNIT_SLOTS];

		if (slot->inUse && slot->unit == unit) {
			result = slot;
			break;
		}

		if (!slot->inUse) {
			slot->unit = unit;
			slot->inUse = 1;
			slot->role = ACRoleUnknown;
			memset(&slot->asbd, 0, sizeof(slot->asbd));
			result = slot;
			break;
		}
	}

	os_unfair_lock_unlock(&gSlotsLock);

	if (!result) return NULL;

	if (result->role == ACRoleUnknown) {
		result->role = ACRoleForUnit(unit);

		UInt32 size = sizeof(AudioStreamBasicDescription);
		AudioStreamBasicDescription asbd;
		memset(&asbd, 0, sizeof(asbd));
		if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
					 kAudioUnitScope_Output, bus, &asbd,
					 &size) == noErr) {
			result->asbd = asbd;
		} else {
			result->role = ACRoleSkip;
		}
	}

	return result;
}

static void ACForgetUnit(AudioUnit unit)
{
	os_unfair_lock_lock(&gSlotsLock);
	for (size_t i = 0; i < AC_UNIT_SLOTS; i++) {
		if (gSlots[i].inUse && gSlots[i].unit == unit) {
			memset(&gSlots[i], 0, sizeof(ACUnitSlot));
			break;
		}
	}
	os_unfair_lock_unlock(&gSlotsLock);
}

static int ACRoleWanted(uint8_t role)
{
	switch (gTargetMode) {
	case ACTargetMixer:
		return role == ACRoleMixer;
	case ACTargetOutput:
		return role == ACRoleOutput;
	case ACTargetAll:
		return role == ACRoleMixer || role == ACRoleOutput;
	case ACTargetAuto:
	default:
		/* Prefer the final output unit. Fall back to the mixer when this
		 * firmware never exposes AudioUnitRender on an output unit. */
		if (atomic_load_explicit(&gSawOutputUnit, memory_order_relaxed))
			return role == ACRoleOutput;
		return role == ACRoleMixer;
	}
}

#pragma mark - Metering

static void ACMeterBlock(const AudioBufferList *list, UInt32 frames, int isFloat,
			 UInt32 channelsPerBuffer)
{
	if (!os_unfair_lock_trylock(&gMeterLock)) return;

	enum { kChunk = 1024 };
	static _Thread_local float mono[kChunk];

	const AudioBuffer *buffer = &list->mBuffers[0];
	if (!buffer->mData || channelsPerBuffer == 0) {
		os_unfair_lock_unlock(&gMeterLock);
		return;
	}

	const UInt32 stride = channelsPerBuffer;
	UInt32 remaining = frames;
	UInt32 offset = 0;

	while (remaining > 0) {
		const UInt32 n = remaining > kChunk ? kChunk : remaining;

		if (isFloat) {
			const float *src = (const float *)buffer->mData;
			for (UInt32 i = 0; i < n; i++)
				mono[i] = src[(offset + i) * stride];
		} else {
			const int16_t *src = (const int16_t *)buffer->mData;
			for (UInt32 i = 0; i < n; i++)
				mono[i] = (float)src[(offset + i) * stride] *
					  (1.0f / 32768.0f);
		}

		ac_meter_process(&gMeter, mono, n);
		offset += n;
		remaining -= n;
	}

	const uint64_t now = ACNowNanos();
	gLastAudioNanos = now;

	/* Publishing at ~30 Hz is enough for the waveform and keeps the render
	 * thread from doing a Mach call on every block. */
	if (gLevelsToken >= 0 && now - gLastPublishNanos > 33000000ULL) {
		gLastPublishNanos = now;
		notify_set_state(gLevelsToken, ac_meter_pack(&gMeter));
	}

	os_unfair_lock_unlock(&gMeterLock);
}

#pragma mark - Render hook

%hookf(OSStatus, AudioUnitRender, AudioUnit inUnit,
       AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp,
       UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData)
{
	OSStatus status = %orig;

	if (status != noErr || ioData == NULL || ioData->mNumberBuffers == 0 ||
	    inNumberFrames == 0)
		return status;

	const uint64_t pending =
		atomic_load_explicit(&gPendingSettings, memory_order_relaxed);
	if (pending != gAppliedSettings) {
		ACApplyPacked(pending);
		gAppliedSettings = pending;
	}

	ACUnitSlot *slot = ACSlotForUnit(inUnit, inBusNumber);
	if (!slot || slot->role == ACRoleSkip || !ACRoleWanted(slot->role))
		return status;

	const AudioStreamBasicDescription *asbd = &slot->asbd;
	if (asbd->mFormatID != kAudioFormatLinearPCM) {
		slot->role = ACRoleSkip;
		return status;
	}

	const int isFloat = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
	const int isS16 = (!isFloat && asbd->mBitsPerChannel == 16);
	if (!isFloat && !isS16) {
		slot->role = ACRoleSkip;
		return status;
	}

	if (asbd->mSampleRate > 0.0) {
		ac_eq_set_sample_rate(&gEq, (float)asbd->mSampleRate);
		if (os_unfair_lock_trylock(&gMeterLock)) {
			if (fabsf(gMeter.sampleRate - (float)asbd->mSampleRate) > 1.0f)
				ac_meter_set_sample_rate(&gMeter,
							 (float)asbd->mSampleRate);
			os_unfair_lock_unlock(&gMeterLock);
		}
	}

	const UInt32 bytesPerSample = isFloat ? sizeof(float) : sizeof(int16_t);
	const int active = ac_eq_is_active(&gEq);

	if (active) ac_eq_begin_block(&gEq);

	UInt32 channelCursor = 0;
	UInt32 firstBufferChannels = 0;

	for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
		AudioBuffer *buffer = &ioData->mBuffers[b];
		if (!buffer->mData || buffer->mDataByteSize == 0) continue;

		const UInt32 channels =
			buffer->mNumberChannels ? buffer->mNumberChannels : 1;
		if (b == 0) firstBufferChannels = channels;

		UInt32 framesInBuffer =
			buffer->mDataByteSize / (bytesPerSample * channels);
		if (framesInBuffer == 0) continue;
		if (framesInBuffer > inNumberFrames) framesInBuffer = inNumberFrames;

		if (active) {
			for (UInt32 c = 0; c < channels; c++) {
				const UInt32 channelIndex =
					(channelCursor + c) % AC_MAX_CHANNELS;

				if (isFloat)
					ac_eq_process_f32(&gEq,
							  ((float *)buffer->mData) + c,
							  framesInBuffer, channels,
							  channelIndex);
				else
					ac_eq_process_s16(&gEq,
							  ((int16_t *)buffer->mData) + c,
							  framesInBuffer, channels,
							  channelIndex);
			}
		}

		channelCursor += channels;
	}

	if (firstBufferChannels > 0)
		ACMeterBlock(ioData, inNumberFrames, isFloat, firstBufferChannels);

	return status;
}

%hookf(OSStatus, AudioComponentInstanceDispose, AudioComponentInstance inInstance)
{
	ACForgetUnit(inInstance);
	return %orig;
}

#pragma mark - Init

static void ACStartIdleWatchdog(void)
{
	/* When playback stops the render thread goes quiet, so nobody would ever
	 * clear the last published levels. Fade them out from a timer instead. */
	dispatch_source_t timer = dispatch_source_create(
		DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
		dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
	if (!timer) return;

	dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
				  120 * NSEC_PER_MSEC, 40 * NSEC_PER_MSEC);
	dispatch_source_set_event_handler(timer, ^{
		if (!os_unfair_lock_trylock(&gMeterLock)) return;

		const uint64_t now = ACNowNanos();
		const int idle = (gLastAudioNanos == 0) ||
				 (now - gLastAudioNanos > 200000000ULL);

		if (idle) {
			ac_meter_decay(&gMeter, 0.55f);
			if (gLevelsToken >= 0)
				notify_set_state(gLevelsToken, ac_meter_pack(&gMeter));
		}

		os_unfair_lock_unlock(&gMeterLock);
	});
	dispatch_resume(timer);
}

static void ACAudioInit(void)
{
	ACInitClock();
	ac_eq_init(&gEq, 48000.0f);
	ac_meter_init(&gMeter, 48000.0f);

	const uint64_t fromDisk = ACReadSettingsFromDisk();
	if (fromDisk & AC_SETTINGS_VALID)
		atomic_store_explicit(&gPendingSettings, fromDisk, memory_order_relaxed);

	notify_register_check(AC_KEY_SETTINGS, &gSettingsToken);
	notify_register_check(AC_KEY_LEVELS, &gLevelsToken);
	if (gLevelsToken >= 0) notify_set_state(gLevelsToken, 0);

	ACPullSettings();

	int liveToken = 0;
	notify_register_dispatch(AC_NOTE_PREFS_CHANGED, &liveToken,
				 dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
				 ^(int token) {
					 ACPullSettings();
				 });

	ACStartIdleWatchdog();
	AC_LOG(@"loaded into mediaserverd, target mode %d", gTargetMode);
}

static void ACRelayPublish(void)
{
	const uint64_t packed = ACReadSettingsFromDisk();
	if (!(packed & AC_SETTINGS_VALID)) return;
	if (gSettingsToken < 0) notify_register_check(AC_KEY_SETTINGS, &gSettingsToken);
	if (gSettingsToken < 0) return;

	notify_set_state(gSettingsToken, packed);
	notify_post(AC_NOTE_PREFS_CHANGED);
}

static void ACRelayInit(void)
{
	ACRelayPublish();

	int token = 0;
	notify_register_dispatch(AC_NOTE_RELAY_SYNC, &token,
				 dispatch_get_main_queue(), ^(int inner) {
					 ACRelayPublish();
				 });
}

%ctor
{
	@autoreleasepool {
		NSString *process = [[NSProcessInfo processInfo] processName] ?: @"";

		if ([process isEqualToString:@"mediaserverd"]) {
			ACAudioInit();
			%init;
		} else if ([process isEqualToString:@"SpringBoard"]) {
			ACRelayInit();
		}
	}
}
