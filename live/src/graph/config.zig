const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn storeCredential(g: anytype, content: []const u8) !void {
    g.db.write_mu.lock();
    defer g.db.write_mu.unlock();

    var cred_h = std.crypto.hash.sha2.Sha256.init(.{});
    cred_h.update(content);
    var cred_digest: [32]u8 = undefined;
    cred_h.final(&cred_digest);
    const id_buf = std.fmt.bytesToHex(cred_digest, .lower);

    const now = std.time.timestamp();
    var st = try g.db.prepare(
        "INSERT OR REPLACE INTO credentials (id, content, created_at) VALUES (?, ?, ?)"
    );
    defer st.finalize();
    try st.bindText(1, &id_buf);
    try st.bindText(2, content);
    try st.bindInt(3, now);
    _ = try st.step();
}

pub fn getLatestCredential(g: anytype, alloc: Allocator) !?[]const u8 {
    var st = try g.db.prepare(
        "SELECT content FROM credentials ORDER BY created_at DESC LIMIT 1"
    );
    defer st.finalize();
    if (!try st.step()) return null;
    return try alloc.dupe(u8, st.columnText(0));
}

pub fn hasLegacyCredential(g: anytype) !bool {
    var st = try g.db.prepare("SELECT 1 FROM credentials LIMIT 1");
    defer st.finalize();
    return try st.step();
}

pub fn clearLegacyCredentials(g: anytype) !void {
    g.db.write_mu.lock();
    defer g.db.write_mu.unlock();
    var st = try g.db.prepare("DELETE FROM credentials");
    defer st.finalize();
    _ = try st.step();
}

pub fn storeConfig(g: anytype, key: []const u8, value: []const u8) !void {
    g.db.write_mu.lock();
    defer g.db.write_mu.unlock();
    var st = try g.db.prepare(
        "INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)"
    );
    defer st.finalize();
    try st.bindText(1, key);
    try st.bindText(2, value);
    _ = try st.step();
}

pub fn getConfig(g: anytype, key: []const u8, alloc: Allocator) !?[]const u8 {
    var st = try g.db.prepare(
        "SELECT value FROM config WHERE key=?"
    );
    defer st.finalize();
    try st.bindText(1, key);
    if (!try st.step()) return null;
    return try alloc.dupe(u8, st.columnText(0));
}

pub fn deleteConfig(g: anytype, key: []const u8) !void {
    g.db.write_mu.lock();
    defer g.db.write_mu.unlock();
    var st = try g.db.prepare("DELETE FROM config WHERE key=?");
    defer st.finalize();
    try st.bindText(1, key);
    _ = try st.step();
}
