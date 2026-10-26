export ARCHS = arm64e
export TARGET = iphone:clang:latest:15.0
export THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DateSpeedBar

DateSpeedBar_FILES = Tweak.xm
DateSpeedBar_CFLAGS = -fobjc-arc
DateSpeedBar_FRAMEWORKS = UIKit CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += dsbprefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall SpringBoard"
