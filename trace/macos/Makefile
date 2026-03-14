LIB_DIR  = lib
ZIG_DIR  = ../..
SCHEME   = RTMify Trace
PROJECT  = RTMify Trace.xcodeproj
ZIG_OPTIMIZE ?= Debug
XCODE_CONFIGURATION ?= Debug
LICENSE_HMAC_KEY_FILE ?=

ifeq ($(strip $(LICENSE_HMAC_KEY_FILE)),)
ifneq ($(strip $(RTMIFY_LICENSE_HMAC_KEY_FILE)),)
RESOLVED_LICENSE_HMAC_KEY_FILE = $(RTMIFY_LICENSE_HMAC_KEY_FILE)
else
RESOLVED_LICENSE_HMAC_KEY_FILE = $(HOME)/.rtmify/secrets/license-hmac-key.txt
endif
else
RESOLVED_LICENSE_HMAC_KEY_FILE = $(LICENSE_HMAC_KEY_FILE)
endif

LICENSE_HMAC_FLAG = -Dlicense-hmac-key-file=$(RESOLVED_LICENSE_HMAC_KEY_FILE)

.PHONY: lib build clean build-universal

lib:
	mkdir -p $(LIB_DIR)
	cd $(ZIG_DIR) && zig build lib -Dtarget=aarch64-macos -Doptimize=$(ZIG_OPTIMIZE) $(LICENSE_HMAC_FLAG)
	cp $(ZIG_DIR)/zig-out/lib/librtmify.a $(LIB_DIR)/librtmify.a

build: lib
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" \
	           -configuration $(XCODE_CONFIGURATION) -derivedDataPath .build

build-universal:
	mkdir -p $(LIB_DIR)
	cd $(ZIG_DIR) && zig build lib -Dtarget=aarch64-macos -Doptimize=$(ZIG_OPTIMIZE) $(LICENSE_HMAC_FLAG)
	cp $(ZIG_DIR)/zig-out/lib/librtmify.a $(LIB_DIR)/librtmify-arm64.a
	cd $(ZIG_DIR) && zig build lib -Dtarget=x86_64-macos  -Doptimize=$(ZIG_OPTIMIZE) $(LICENSE_HMAC_FLAG)
	cp $(ZIG_DIR)/zig-out/lib/librtmify.a $(LIB_DIR)/librtmify-x64.a
	lipo -create $(LIB_DIR)/librtmify-arm64.a $(LIB_DIR)/librtmify-x64.a \
	     -output $(LIB_DIR)/librtmify.a

clean:
	rm -rf $(LIB_DIR) .build
