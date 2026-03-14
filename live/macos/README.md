# RTMify Live — macOS App

Native SwiftUI menu-bar shell for `rtmify-live`. The app bundles the Zig
runtime, starts it locally, opens the dashboard, and presents the signed-license
file gate when Live is not licensed.

## Prerequisites

- Xcode 16+
- Zig 0.15.2
- a signed-license HMAC key file for ReleaseSafe builds

The license key file is a local operator/developer secret, not something stored
in the repo. It must contain exactly 64 lowercase hex characters.

## Build

From this directory:

```sh
make app LICENSE_HMAC_KEY_FILE=/absolute/path/to/license-hmac-key.txt
```

This builds the embedded `rtmify-live` runtime in `ReleaseSafe`, copies it into
the app resources, then runs `xcodebuild` for the native shell.

You can also provide the key path via environment variable instead of a make
variable:

```sh
export RTMIFY_LICENSE_HMAC_KEY_FILE=/absolute/path/to/license-hmac-key.txt
make app
```

Key resolution order for `make app` and release builds:

1. `LICENSE_HMAC_KEY_FILE=/path/to/key.txt`
2. `RTMIFY_LICENSE_HMAC_KEY_FILE`
3. `~/.rtmify/secrets/license-hmac-key.txt`

For release packaging, prefer:

```sh
cd /Users/colinsteele/Projects/rtmify/sys
./release.sh
```

That script builds the embedded runtime, the native app, the operator generator,
and smoke-verifies generated licenses before writing `dist/<version>/`.

Output:

```text
.build/Build/Products/Release/RTMify Live.app
```

## Why the key file is required

The macOS app bundles a release build of `rtmify-live`. Release builds verify
signed `license.json` files with the real HMAC key, so they require either:

- `LICENSE_HMAC_KEY_FILE=/path/to/key.txt`, or
- `RTMIFY_LICENSE_HMAC_KEY_FILE=/path/to/key.txt`

Without one of those, the Zig build fails intentionally.
