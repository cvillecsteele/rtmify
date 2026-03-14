ZIG_DIR  = ../..
SCHEME   = RTMify Live
PROJECT  = RTMify Live.xcodeproj
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

.PHONY: bin app clean

bin:
	cd $(ZIG_DIR) && zig build live -Dtarget=aarch64-macos -Doptimize=ReleaseSafe $(LICENSE_HMAC_FLAG)
	mkdir -p "RTMify Live/Resources"
	cp $(ZIG_DIR)/zig-out/bin/rtmify-live "RTMify Live/Resources/rtmify-live"
	chmod +x "RTMify Live/Resources/rtmify-live"

app: bin
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" \
	           -configuration Release -derivedDataPath .build

clean:
	rm -rf .build "RTMify Live/Resources/rtmify-live"
