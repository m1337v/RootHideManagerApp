ARCHS = arm64
TARGET = iphone:latest:15.0
DEB_ARCH = iphoneos-arm64
IPHONEOS_DEPLOYMENT_TARGET = 15.0

INSTALL_TARGET_PROCESSES = varClean
THEOS_PACKAGE_SCHEME = rootless
include $(THEOS)/makefiles/common.mk

XCODE_SCHEME = varClean
XCODEPROJ_NAME = varClean

XCODEFLAGS = MARKETING_VERSION=$(THEOS_PACKAGE_BASE_VERSION) \
	IPHONEOS_DEPLOYMENT_TARGET="$(IPHONEOS_DEPLOYMENT_TARGET)" \
	CODE_SIGN_IDENTITY="" \
	AD_HOC_CODE_SIGNING_ALLOWED=YES
CODESIGN_FLAGS = -Sentitlements.plist
INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/xcodeproj.mk

clean::
	rm -rf ./packages/*

after-install::
	install.exec 'uiopen -b com.m1337.varclean'
