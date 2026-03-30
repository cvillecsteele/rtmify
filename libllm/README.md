# libllm

`libllm` is parked spike infrastructure.

It exists to provide a generic local multimodal inference layer for future RTMify work, with `libtraveler` as the first domain-specific consumer.

Current status:

- committed and kept intentionally
- not integrated into Trace or Live product binaries
- not part of the Live V1 shipping plan
- not something operators or customers should be asked to configure today

If this work is resumed, start with:

- [traveler-spike.md](/Users/colinsteele/Projects/rtmify/sys/docs/traveler-spike.md)
- [lib.zig](/Users/colinsteele/Projects/rtmify/sys/libllm/src/lib.zig)
- [provider.zig](/Users/colinsteele/Projects/rtmify/sys/libllm/src/provider.zig)

Do not assume the existence of any external PRD. The code and the spike doc are the intended handoff context.
