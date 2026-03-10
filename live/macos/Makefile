ZIG_DIR  = ../..
SCHEME   = RTMify Live
PROJECT  = RTMify Live.xcodeproj

.PHONY: bin app clean

bin:
	cd $(ZIG_DIR) && zig build live -Dtarget=aarch64-macos -Doptimize=ReleaseSafe
	mkdir -p "RTMify Live/Resources"
	cp $(ZIG_DIR)/zig-out/bin/rtmify-live "RTMify Live/Resources/rtmify-live"
	chmod +x "RTMify Live/Resources/rtmify-live"

app: bin
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" \
	           -configuration Release -derivedDataPath .build

clean:
	rm -rf .build "RTMify Live/Resources/rtmify-live"
