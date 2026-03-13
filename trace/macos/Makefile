LIB_DIR  = lib
ZIG_DIR  = ../..
SCHEME   = RTMify Trace
PROJECT  = RTMify Trace.xcodeproj
ZIG_OPTIMIZE ?= Debug
XCODE_CONFIGURATION ?= Debug

.PHONY: build clean build-universal

build:
	mkdir -p $(LIB_DIR)
	cd $(ZIG_DIR) && zig build lib -Dtarget=aarch64-macos -Doptimize=$(ZIG_OPTIMIZE)
	cp $(ZIG_DIR)/zig-out/lib/librtmify.a $(LIB_DIR)/librtmify.a
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" \
	           -configuration $(XCODE_CONFIGURATION) -derivedDataPath .build

build-universal:
	mkdir -p $(LIB_DIR)
	cd $(ZIG_DIR) && zig build lib -Dtarget=aarch64-macos -Doptimize=$(ZIG_OPTIMIZE)
	cp $(ZIG_DIR)/zig-out/lib/librtmify.a $(LIB_DIR)/librtmify-arm64.a
	cd $(ZIG_DIR) && zig build lib -Dtarget=x86_64-macos  -Doptimize=$(ZIG_OPTIMIZE)
	cp $(ZIG_DIR)/zig-out/lib/librtmify.a $(LIB_DIR)/librtmify-x64.a
	lipo -create $(LIB_DIR)/librtmify-arm64.a $(LIB_DIR)/librtmify-x64.a \
	     -output $(LIB_DIR)/librtmify.a

clean:
	rm -rf $(LIB_DIR) .build
