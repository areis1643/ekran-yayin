ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
T ?= /home/alir/theos/toolchain/linux/iphone/bin
S ?= /home/alir/theos/sdks/iPhoneOS9.3.sdk
CC := $(T)/clang
.DEFAULT_GOAL := all
MAKEFLAGS += -j8
LIB := $(ROOT)/vendor/UxPlay/lib
BUILD := $(ROOT)/build
# This revision separates the system Bonjour adapter from the common dnssd.c.
SOURCES := $(filter-out $(LIB)/compat.c,$(wildcard $(LIB)/*.c)) $(wildcard $(LIB)/playfair/*.c) $(wildcard $(LIB)/llhttp/*.c) $(LIB)/dns_sd/dns_sd.c
OBJECTS := $(patsubst $(LIB)/%.c,$(BUILD)/obj-alici/%.o,$(SOURCES)) $(BUILD)/obj-alici/aracairplay.o $(BUILD)/obj-alici/ios.o
CPPFLAGS := -I$(ROOT)/deps/include -I$(LIB) -I$(LIB)/playfair -I$(LIB)/llhttp -include $(ROOT)/poc/uyum/ios9.h -DNOHOLD -DPLIST_210 -DPLIST_230
CFLAGS := -target armv7-apple-ios9.0 -isysroot $(S) -O2 -Wall -MMD -MP
LDFLAGS := -target armv7-apple-ios9.0 -isysroot $(S) -L$(ROOT)/poc/sdkstub -L$(ROOT)/vendor/openssl-1.1.1w-build-armv7/sdkstub -L/home/alir/projeler/ekran-yayin/iPad/sdkstub -L$(ROOT)/deps/lib
.PHONY: all clean
all: $(BUILD)/aracairplay
$(BUILD)/aracairplay: $(OBJECTS) $(ROOT)/alici/Makefile $(ROOT)/alici/aracairplay.entitlements $(wildcard $(ROOT)/poc/sdkstub/*.tbd)
	$(CC) $(LDFLAGS) $(OBJECTS) -lcrypto -lplist-2.0 -lpthread -framework Foundation -framework AVFoundation -framework AudioToolbox -framework CoreFoundation -o $@
	$(T)/ldid -S$(ROOT)/alici/aracairplay.entitlements $@
$(BUILD)/obj-alici/%.o: $(LIB)/%.c $(ROOT)/poc/uyum/ios9.h
	@mkdir -p $(@D)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@
$(BUILD)/obj-alici/aracairplay.o: $(ROOT)/alici/aracairplay.c $(ROOT)/poc/uyum/ios9.h
	@mkdir -p $(@D)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@
$(BUILD)/obj-alici/ios.o: $(ROOT)/alici/ios.m $(ROOT)/alici/ios.h
	@mkdir -p $(@D)
	$(CC) $(CPPFLAGS) $(CFLAGS) -fobjc-arc -c $< -o $@
clean:
	rm -f $(OBJECTS) $(OBJECTS:.o=.d) $(BUILD)/aracairplay
-include $(OBJECTS:.o=.d)
