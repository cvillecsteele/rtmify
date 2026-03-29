const types = @import("types.zig");

pub fn isAccepted(status: types.ValidationStatus, reason: types.RejectionReason) bool {
    return status == .accepted and reason == .ok;
}
