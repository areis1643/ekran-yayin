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

include $(THEOS_MAKE_PATH)/application.mk
