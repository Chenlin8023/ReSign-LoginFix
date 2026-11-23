# theos 工程 —— 由 GitHub 的 macOS 云服务器编译，本地不需要任何工具链
#
# 产物：packages/jp.soh.resignpatch_0.1.0_iphoneos-arm64e.deb

TARGET := iphone:clang:latest:16.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = ReSign

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ReSignPatch

ReSignPatch_FILES = Tweak.xm
ReSignPatch_CFLAGS = -fobjc-arc
ReSignPatch_FRAMEWORKS = Foundation UIKit Security
# AKAppleIDSession 在私有的 AuthKit 里
ReSignPatch_PRIVATE_FRAMEWORKS = AuthKit

include $(THEOS_MAKE_PATH)/tweak.mk
