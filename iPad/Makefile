TARGET := iphone:clang:9.3:9.0
ARCHS = armv7

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = Arac
Arac_FILES = main.m
Arac_FRAMEWORKS = UIKit AVFoundation CoreMedia AudioToolbox QuartzCore
Arac_CFLAGS = -fobjc-arc
# SDK'daki libSystem.tbd, cihazda bulunmayan bir liblaunch yeniden-dışa-aktarımı
# içeriyor; yerel kopya bu satır olmadan bağlanır (yalnızca derleme ortamı düzeltmesi).
Arac_LDFLAGS = -L$(CURDIR)/sdkstub

TOOL_NAME = aracbaslat
aracbaslat_FILES = aracbaslat.m
aracbaslat_FRAMEWORKS = Foundation CoreFoundation
aracbaslat_CFLAGS = -fobjc-arc
aracbaslat_LDFLAGS = -L$(CURDIR)/sdkstub
aracbaslat_INSTALL_PATH = /usr/libexec
aracbaslat_CODESIGN_FLAGS = -Saracbaslat.entitlements

include $(THEOS_MAKE_PATH)/application.mk
include $(THEOS_MAKE_PATH)/tool.mk

# Yalnız üst düzey çağrıda: alt make'lerde THEOS_CURRENT_INSTANCE doludur.
ifeq ($(THEOS_CURRENT_INSTANCE),)
before-stage::
	$(MAKE) -C $(CURDIR)/../airplay/alici

after-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/usr/libexec"$(ECHO_END)
	$(ECHO_NOTHING)cp "$(CURDIR)/../airplay/build/aracairplay" "$(THEOS_STAGING_DIR)/usr/libexec/aracairplay"$(ECHO_END)
	$(ECHO_NOTHING)chmod 755 "$(THEOS_STAGING_DIR)/usr/libexec/aracairplay"$(ECHO_END)
endif
