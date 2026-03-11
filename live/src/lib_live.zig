/// lib_live.zig — test root for live modules.
/// `zig build test-live` runs all tests in db.zig, graph_live.zig, and sheets.zig.
const std = @import("std");

pub const db = @import("db.zig");
pub const graph_live = @import("graph_live.zig");
pub const json_util = @import("json_util.zig");
pub const sheets = @import("sheets.zig");
pub const provider_common = @import("provider_common.zig");
pub const provider_google = @import("provider_google.zig");
pub const provider_excel = @import("provider_excel.zig");
pub const online_provider = @import("online_provider.zig");
pub const connection = @import("connection.zig");
pub const sync_live = @import("sync_live.zig");
pub const mcp = @import("mcp.zig");
pub const repo = @import("repo.zig");
pub const annotations = @import("annotations.zig");
pub const git = @import("git.zig");
pub const profile = @import("profile.zig");
pub const chain = @import("chain.zig");
pub const provision = @import("provision.zig");
pub const adapter = @import("adapter.zig");
pub const server = @import("server.zig");
pub const main_live = @import("main_live.zig");

test {
    _ = db;
    _ = graph_live;
    _ = json_util;
    _ = sheets;
    _ = provider_common;
    _ = provider_google;
    _ = provider_excel;
    _ = online_provider;
    _ = connection;
    _ = sync_live;
    _ = mcp;
    _ = repo;
    _ = annotations;
    _ = git;
    _ = profile;
    _ = chain;
    _ = provision;
    _ = adapter;
    _ = server;
    _ = main_live;
}
