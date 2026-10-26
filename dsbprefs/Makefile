include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = DateSpeedBarPrefs

DateSpeedBarPrefs_FILES = DSBRootListController.m
DateSpeedBarPrefs_INSTALL_PATH = /Library/PreferenceBundles
DateSpeedBarPrefs_CFLAGS = -fobjc-arc
DateSpeedBarPrefs_FRAMEWORKS = UIKit
DateSpeedBarPrefs_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/DateSpeedBar.plist"$(ECHO_END)
