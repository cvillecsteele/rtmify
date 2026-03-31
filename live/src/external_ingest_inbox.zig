const mod = @import("external_ingest_inbox/mod.zig");

pub const InboxCtx = mod.InboxCtx;
pub const destroyInboxCtx = mod.destroyInboxCtx;
pub const inboxThread = mod.inboxThread;
pub const processInboxOnce = mod.processInboxOnce;
