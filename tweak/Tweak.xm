TARGET := iphone:clang:latest:16.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = ReSign

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ReSignPatch

ReSignPatch_FILES = Tweak.xm
ReSignPatch_CFLAGS = -fobjc-arc
ReSignPatch_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
