# libtraveler

`libtraveler` is parked spike code.

It implements traveler-specific prompt construction, parsing, normalization, validation, and rejection logic on top of an injected `libllm` provider.

Current status:

- committed and intentionally preserved
- not integrated into Live V1
- not part of current product packaging, release, or operator workflow
- intended as a restart point for a future Live V2-style effort if local traveler extraction becomes product-priority work again

If this work is resumed, start with:

- [traveler-spike.md](/Users/colinsteele/Projects/rtmify/sys/docs/traveler-spike.md)
- [lib.zig](/Users/colinsteele/Projects/rtmify/sys/libtraveler/src/lib.zig)
- [extract.zig](/Users/colinsteele/Projects/rtmify/sys/libtraveler/src/extract.zig)
- [validate.zig](/Users/colinsteele/Projects/rtmify/sys/libtraveler/src/validate.zig)

The code is not deprecated. It is parked.
