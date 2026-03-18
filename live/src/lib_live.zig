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
pub const secure_store = @import("secure_store.zig");
pub const secure_store_test = @import("secure_store_test.zig");
pub const sync_live = @import("sync_live.zig");
pub const mcp = @import("mcp.zig");
pub const repo = @import("repo.zig");
pub const annotations = @import("annotations.zig");
pub const git = @import("git.zig");
pub const chain = @import("chain.zig");
pub const provision = @import("provision.zig");
pub const guide_catalog = @import("guide_catalog.zig");
pub const design_history = @import("design_history.zig");
pub const design_history_md = @import("design_history_md.zig");
pub const design_history_pdf = @import("design_history_pdf.zig");
pub const test_results = @import("test_results.zig");
pub const test_results_auth = @import("test_results_auth.zig");
pub const external_ingest_inbox = @import("external_ingest_inbox.zig");
pub const bom = @import("bom.zig");
pub const soup = @import("soup.zig");
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
    _ = secure_store;
    _ = secure_store_test;
    _ = sync_live;
    _ = mcp;
    _ = repo;
    _ = annotations;
    _ = git;
    _ = chain;
    _ = provision;
    _ = guide_catalog;
    _ = design_history;
    _ = design_history_md;
    _ = design_history_pdf;
    _ = test_results;
    _ = test_results_auth;
    _ = external_ingest_inbox;
    _ = bom;
    _ = soup;
    _ = adapter;
    _ = server;
    _ = main_live;
}
