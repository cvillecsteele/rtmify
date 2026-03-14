# RTMify Trace — Native App Builds

This directory contains the native desktop shells for RTMify Trace:

- macOS app: [/Users/colinsteele/Projects/rtmify/sys/trace/macos/README.md](/Users/colinsteele/Projects/rtmify/sys/trace/macos/README.md)
- Windows GUI app: [/Users/colinsteele/Projects/rtmify/sys/trace/windows/README.md](/Users/colinsteele/Projects/rtmify/sys/trace/windows/README.md)

If you just need the build commands, use these.

For operator/release work, use the single supported release flow:

```sh
cd /Users/colinsteele/Projects/rtmify/sys
./release.sh
```

`release.sh` resolves the signing key once, builds Trace, Live,
`rtmify-license-gen`, the macOS apps, the Windows shells, and then smoke-checks
generated licenses against the freshly built binaries before packaging
`dist/<version>/`.

## macOS app

Build the native SwiftUI app:

```sh
cd /Users/colinsteele/Projects/rtmify/sys/trace/macos
make build
```

Output:

- `.build/Build/Products/Release/RTMify Trace.app`

Open the Xcode project for local development:

```sh
cd /Users/colinsteele/Projects/rtmify/sys/trace/macos
make lib
open "RTMify Trace.xcodeproj"
```

Release builds resolve the signing key in this order:

1. `LICENSE_HMAC_KEY_FILE=/path/to/key.txt`
2. `RTMIFY_LICENSE_HMAC_KEY_FILE`
3. `~/.rtmify/secrets/license-hmac-key.txt`

For a universal app build, see:

- [/Users/colinsteele/Projects/rtmify/sys/trace/macos/README.md](/Users/colinsteele/Projects/rtmify/sys/trace/macos/README.md)

## Windows GUI app

Build the native Win32 GUI executable:

```sh
cd /Users/colinsteele/Projects/rtmify/sys
zig build win-gui -Dtarget=x86_64-windows -Doptimize=ReleaseSafe
```

Output:

- `/Users/colinsteele/Projects/rtmify/sys/zig-out/bin/rtmify-trace.exe`

ARM64 Windows:

```sh
cd /Users/colinsteele/Projects/rtmify/sys
zig build win-gui -Dtarget=aarch64-windows -Doptimize=ReleaseSafe
```

For the Windows shell layout and Make targets, see:

- [/Users/colinsteele/Projects/rtmify/sys/trace/windows/README.md](/Users/colinsteele/Projects/rtmify/sys/trace/windows/README.md)

## Shared CLI / Library Context

The Zig CLI/library build graph and shared release targets live at:

- [/Users/colinsteele/Projects/rtmify/sys/build.zig](/Users/colinsteele/Projects/rtmify/sys/build.zig)
- [/Users/colinsteele/Projects/rtmify/sys/lib/README.md](/Users/colinsteele/Projects/rtmify/sys/lib/README.md)
