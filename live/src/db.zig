/// db.zig — thin SQLite C interop wrapper for rtmify-live.
/// Never exposes sqlite3 types to callers.
const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("sqlite3.h");
});

// Use SQLITE_STATIC (null destructor) for all binds.
// Safe because our API always follows bind → step → reset/finalize in that order,
// so the caller's slice is always alive for the duration of the SQLite call.
// SQLITE_STATIC (-1 cast to fn ptr) cannot be expressed in Zig 0.15.2.
const SQLITE_STATIC: c.sqlite3_destructor_type = null;

// ---------------------------------------------------------------------------
// Error set
// ---------------------------------------------------------------------------

pub const DbError = error{
    Open,
    Exec,
    Prepare,
    Bind,
    Step,
    OutOfMemory,
};

fn checkRc(db_conn: ?*c.sqlite3, rc: c_int) DbError!void {
    if (rc == c.SQLITE_OK or rc == c.SQLITE_DONE or rc == c.SQLITE_ROW) return;
    if (db_conn) |conn| {
        const msg = c.sqlite3_errmsg(conn);
        std.log.err("SQLite error {d}: {s}", .{ rc, msg });
    }
    return error.Exec;
}

// ---------------------------------------------------------------------------
// Statement
// ---------------------------------------------------------------------------

pub const Stmt = struct {
    st: *c.sqlite3_stmt,
    db_mu: *std.Thread.Mutex,

    pub fn bindText(s: *Stmt, idx: c_int, val: []const u8) DbError!void {
        s.db_mu.lock();
        defer s.db_mu.unlock();
        const rc = c.sqlite3_bind_text(s.st, idx, val.ptr, @intCast(val.len), SQLITE_STATIC);
        if (rc != c.SQLITE_OK) return error.Bind;
    }

    pub fn bindTextZ(s: *Stmt, idx: c_int, val: [*:0]const u8) DbError!void {
        s.db_mu.lock();
        defer s.db_mu.unlock();
        const rc = c.sqlite3_bind_text(s.st, idx, val, -1, SQLITE_STATIC);
        if (rc != c.SQLITE_OK) return error.Bind;
    }

    pub fn bindInt(s: *Stmt, idx: c_int, val: i64) DbError!void {
        s.db_mu.lock();
        defer s.db_mu.unlock();
        const rc = c.sqlite3_bind_int64(s.st, idx, val);
        if (rc != c.SQLITE_OK) return error.Bind;
    }

    pub fn bindNull(s: *Stmt, idx: c_int) DbError!void {
        s.db_mu.lock();
        defer s.db_mu.unlock();
        const rc = c.sqlite3_bind_null(s.st, idx);
        if (rc != c.SQLITE_OK) return error.Bind;
    }

    /// Returns true if a row is available, false if done.
    pub fn step(s: *Stmt) DbError!bool {
        s.db_mu.lock();
        defer s.db_mu.unlock();
        const rc = c.sqlite3_step(s.st);
        if (rc == c.SQLITE_ROW) return true;
        if (rc == c.SQLITE_DONE) return false;
        return error.Step;
    }

    /// Returns a slice pointing into SQLite's internal buffer.
    /// Valid only until the next step/reset/finalize call.
    pub fn columnText(s: *Stmt, idx: c_int) []const u8 {
        s.db_mu.lock();
        defer s.db_mu.unlock();
        const ptr = c.sqlite3_column_text(s.st, idx);
        if (ptr == null) return "";
        const len = c.sqlite3_column_bytes(s.st, idx);
        return ptr[0..@intCast(len)];
    }

    pub fn columnInt(s: *Stmt, idx: c_int) i64 {
        s.db_mu.lock();
        defer s.db_mu.unlock();
        return c.sqlite3_column_int64(s.st, idx);
    }

    pub fn columnIsNull(s: *Stmt, idx: c_int) bool {
        s.db_mu.lock();
        defer s.db_mu.unlock();
        return c.sqlite3_column_type(s.st, idx) == c.SQLITE_NULL;
    }

    pub fn reset(s: *Stmt) void {
        s.db_mu.lock();
        defer s.db_mu.unlock();
        _ = c.sqlite3_reset(s.st);
        _ = c.sqlite3_clear_bindings(s.st);
    }

    pub fn finalize(s: *Stmt) void {
        s.db_mu.lock();
        defer s.db_mu.unlock();
        _ = c.sqlite3_finalize(s.st);
    }
};

// ---------------------------------------------------------------------------
// Database
// ---------------------------------------------------------------------------

pub const Db = struct {
    conn: *c.sqlite3,
    /// Serializes all write operations. WAL mode allows concurrent reads.
    write_mu: std.Thread.Mutex = .{},
    /// SQLite connection handles are not safe for concurrent prepare/step access.
    conn_mu: std.Thread.Mutex = .{},

    pub fn open(path: [:0]const u8) DbError!Db {
        var conn: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path.ptr, &conn);
        if (rc != c.SQLITE_OK or conn == null) {
            if (conn) |p| _ = c.sqlite3_close(p);
            return error.Open;
        }
        var db = Db{ .conn = conn.? };
        // WAL mode: readers never block writers, writers never block readers
        try db.exec("PRAGMA journal_mode=WAL");
        // Busy timeout: wait up to 5s for write lock
        _ = c.sqlite3_busy_timeout(db.conn, 5000);
        return db;
    }

    pub fn close(db: *Db) void {
        _ = c.sqlite3_close(db.conn);
    }

    pub fn exec(db: *Db, sql: [:0]const u8) DbError!void {
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(db.conn, sql.ptr, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg) |m| {
                std.log.err("sqlite3_exec: {s}", .{m});
                c.sqlite3_free(m);
            }
            return error.Exec;
        }
    }

    pub fn prepare(db: *Db, sql: [:0]const u8) DbError!Stmt {
        db.conn_mu.lock();
        defer db.conn_mu.unlock();
        var st: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(db.conn, sql.ptr, -1, &st, null);
        if (rc != c.SQLITE_OK or st == null) {
            std.log.err("prepare failed ({d}): {s}", .{ rc, c.sqlite3_errmsg(db.conn) });
            return error.Prepare;
        }
        return Stmt{ .st = st.?, .db_mu = &db.conn_mu };
    }

    pub fn initSchema(db: *Db) DbError!void {
        db.write_mu.lock();
        defer db.write_mu.unlock();
        try db.exec(
            \\CREATE TABLE IF NOT EXISTS nodes (
            \\    id          TEXT PRIMARY KEY,
            \\    type        TEXT NOT NULL,
            \\    properties  TEXT NOT NULL,
            \\    row_hash    TEXT,
            \\    created_at  INTEGER NOT NULL,
            \\    updated_at  INTEGER NOT NULL,
            \\    suspect     INTEGER NOT NULL DEFAULT 0,
            \\    suspect_reason TEXT
            \\);
            \\CREATE TABLE IF NOT EXISTS node_history (
            \\    node_id       TEXT NOT NULL,
            \\    properties    TEXT NOT NULL,
            \\    superseded_at INTEGER NOT NULL
            \\);
            \\CREATE TABLE IF NOT EXISTS edges (
            \\    id          TEXT PRIMARY KEY,
            \\    from_id     TEXT NOT NULL,
            \\    to_id       TEXT NOT NULL,
            \\    label       TEXT NOT NULL,
            \\    properties  TEXT,
            \\    created_at  INTEGER NOT NULL
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_edges_from   ON edges(from_id);
            \\CREATE INDEX IF NOT EXISTS idx_edges_to     ON edges(to_id);
            \\CREATE INDEX IF NOT EXISTS idx_nodes_type   ON nodes(type);
            \\CREATE INDEX IF NOT EXISTS idx_history_node ON node_history(node_id);
            \\CREATE TABLE IF NOT EXISTS credentials (
            \\    id         TEXT PRIMARY KEY,
            \\    content    TEXT NOT NULL,
            \\    created_at INTEGER NOT NULL
            \\);
            \\CREATE TABLE IF NOT EXISTS config (
            \\    key   TEXT PRIMARY KEY,
            \\    value TEXT NOT NULL
            \\);
            \\CREATE TABLE IF NOT EXISTS runtime_diagnostics (
            \\    dedupe_key   TEXT PRIMARY KEY,
            \\    code         INTEGER NOT NULL,
            \\    severity     TEXT NOT NULL,
            \\    title        TEXT NOT NULL,
            \\    message      TEXT NOT NULL,
            \\    source       TEXT NOT NULL,
            \\    subject      TEXT,
            \\    details_json TEXT NOT NULL,
            \\    updated_at   INTEGER NOT NULL
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_runtime_diag_source ON runtime_diagnostics(source);
            \\CREATE INDEX IF NOT EXISTS idx_runtime_diag_subject ON runtime_diagnostics(subject);
        );
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "open in-memory db" {
    var db = try Db.open(":memory:");
    defer db.close();
}

test "exec and prepare" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE t (id INTEGER, val TEXT)");
    var st = try db.prepare("INSERT INTO t VALUES (?, ?)");
    defer st.finalize();
    try st.bindInt(1, 42);
    try st.bindText(2, "hello");
    _ = try st.step();
    st.reset();

    var q = try db.prepare("SELECT id, val FROM t");
    defer q.finalize();
    const has_row = try q.step();
    try testing.expect(has_row);
    try testing.expectEqual(@as(i64, 42), q.columnInt(0));
    try testing.expectEqualStrings("hello", q.columnText(1));
}

test "initSchema is idempotent" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.initSchema();
    try db.initSchema(); // second call must not fail
}

test "WAL pragma set" {
    var db = try Db.open(":memory:");
    defer db.close();
    // WAL is a no-op on :memory:, but it must not error
    try db.exec("PRAGMA journal_mode=WAL");
}
