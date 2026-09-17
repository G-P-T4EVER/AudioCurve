# AudioCurve - rootless build for iOS 15 and newer.
# Use THEOS_PACKAGE_SCHEME= (empty) for rootful jailbreaks such as unc0ver/checkra1n.

export THEOS_PACKAGE_SCHEME ?= rootless
export ARCHS ?= arm64 arm64e
export TARGET ?= iphone:clang:latest:15.0

INSTALL_TARGET_PROCESSES = mediaserverd SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AudioCurve

AudioCurve_FILES = Tweak.xm eq_dsp.c ac_meter.c
AudioCurve_CFLAGS = -O2 -Wall -Wno-unused-function -ffast-math
AudioCurve_FRAMEWORKS = AudioToolbox Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += App

include $(THEOS_MAKE_PATH)/aggregate.mk

# Run the host side DSP tests: make dsptest
.PHONY: dsptest
dsptest:
	@cc -O2 -I. -o /tmp/ac_test_dsp tests/test_dsp.c eq_dsp.c ac_meter.c -lm
	@/tmp/ac_test_dsp
