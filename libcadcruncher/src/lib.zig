pub const detect = @import("detect.zig");
pub const cfb = @import("cfb.zig");
pub const evidence = @import("evidence.zig");
pub const normalize = @import("normalize.zig");
pub const altium = @import("altium.zig");
pub const eval = @import("eval.zig");

test {
    _ = detect;
    _ = cfb;
    _ = evidence;
    _ = normalize;
    _ = altium;
    _ = eval;
}
