include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = AudioCurve

AudioCurve_FILES = main.m ACAppDelegate.m ACSettings.m ACLevelFeed.m \
                   ACNowPlaying.m ACCurveView.m ACRootListViewController.m \
                   ACEqualizerViewController.m
AudioCurve_CFLAGS = -fobjc-arc -Wall -I..
AudioCurve_FRAMEWORKS = UIKit CoreGraphics QuartzCore
AudioCurve_PRIVATE_FRAMEWORKS =
AudioCurve_LDFLAGS = -Wl,-no_warn_duplicate_libraries
AudioCurve_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk
