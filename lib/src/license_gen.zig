const std = @import("std");
const rtmify = @import("rtmify");
const license = rtmify.license;

fn usage() []const u8 {
    return
        \\rtmify-license-gen --product <trace|live> --tier <lab|individual|team|site> --to <email> [--org <name>] (--perpetual | --expires <YYYY-MM-DD>) --out <path>
        \\
    ;
}

fn parseProduct(value: []const u8) !license.LicenseProduct {
    return std.meta.stringToEnum(license.LicenseProduct, value) orelse error.InvalidProduct;
}

fn parseTier(value: []const u8) !license.LicenseTier {
    return std.meta.stringToEnum(license.LicenseTier, value) orelse error.InvalidTier;
}

fn parseDate(value: []const u8) !i64 {
    if (value.len != 10 or value[4] != '-' or value[7] != '-') return error.InvalidDate;
    const year = try std.fmt.parseInt(i32, value[0..4], 10);
    const month = try std.fmt.parseInt(u8, value[5..7], 10);
    const day = try std.fmt.parseInt(u8, value[8..10], 10);
    if (month < 1 or month > 12 or day < 1 or day > 31) return error.InvalidDate;

    const month_i32: i32 = @intCast(month);
    const day_i32: i32 = @intCast(day);
    const y = year - (if (month <= 2) @as(i32, 1) else @as(i32, 0));
    const era = @divFloor(y, 400);
    const yoe: i32 = y - era * 400;
    const mp: i32 = if (month > 2) month_i32 - 3 else month_i32 + 9;
    const doy: i32 = @divFloor(153 * mp + 2, 5) + day_i32 - 1;
    const doe: i32 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days_since_epoch: i64 = @as(i64, era) * 146097 + doe - 719468;
    return days_since_epoch * 86_400;
}

fn productPrefix(product: license.LicenseProduct) []const u8 {
    return switch (product) {
        .trace => "TRACE",
        .live => "LIVE",
    };
}

fn nextSequence(alloc: std.mem.Allocator, product: license.LicenseProduct) !u32 {
    const home_var = if (@import("builtin").os.tag == .windows) "USERPROFILE" else "HOME";
    const home = try std.process.getEnvVarOwned(alloc, home_var);
    defer alloc.free(home);
    const dir = try std.fs.path.join(alloc, &.{ home, ".rtmify" });
    defer alloc.free(dir);
    try std.fs.cwd().makePath(dir);
    const seq_name = try std.fmt.allocPrint(alloc, "license-seq-{s}.txt", .{@tagName(product)});
    defer alloc.free(seq_name);
    const path = try std.fs.path.join(alloc, &.{ dir, seq_name });
    defer alloc.free(path);
    const existing = std.fs.cwd().readFileAlloc(alloc, path, 64) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (existing) |bytes| alloc.free(bytes);
    const current = if (existing) |bytes| try std.fmt.parseInt(u32, std.mem.trim(u8, bytes, " \t\r\n"), 10) else 0;
    const next = current + 1;
    const contents = try std.fmt.allocPrint(alloc, "{d}\n", .{next});
    defer alloc.free(contents);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = contents });
    return next;
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var product: ?license.LicenseProduct = null;
    var tier: ?license.LicenseTier = null;
    var issued_to: ?[]const u8 = null;
    var org: ?[]const u8 = null;
    var expires_at: ?i64 = null;
    var perpetual = false;
    var out_path: ?[]const u8 = null;

    var args = try std.process.argsWithAllocator(gpa);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--product")) {
            product = try parseProduct(args.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--tier")) {
            tier = try parseTier(args.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--to")) {
            issued_to = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--org")) {
            org = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--expires")) {
            expires_at = try parseDate(args.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--perpetual")) {
            perpetual = true;
        } else if (std.mem.eql(u8, arg, "--out")) {
            out_path = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--help")) {
            try std.fs.File.stdout().deprecatedWriter().writeAll(usage());
            return;
        } else {
            return error.UnknownArgument;
        }
    }

    if (perpetual and expires_at != null) return error.ConflictingExpiry;
    if (!perpetual and expires_at == null) return error.MissingExpiry;
    const resolved_product = product orelse return error.MissingProduct;
    const resolved_tier = tier orelse return error.MissingTier;
    const resolved_to = issued_to orelse return error.MissingIssuedTo;
    const resolved_out = out_path orelse return error.MissingOutput;
    const seq = try nextSequence(gpa, resolved_product);
    const year = 1970 + @divFloor(std.time.timestamp(), 31_536_000);

    var payload = license.LicensePayload{
        .schema = 1,
        .license_id = try std.fmt.allocPrint(gpa, "{s}-{d}-{d:0>4}", .{ productPrefix(resolved_product), year, seq }),
        .product = resolved_product,
        .tier = resolved_tier,
        .issued_to = try gpa.dupe(u8, resolved_to),
        .issued_at = std.time.timestamp(),
        .expires_at = expires_at,
        .org = if (org) |value| try gpa.dupe(u8, value) else null,
    };
    defer payload.deinit(gpa);
    const key = try license.defaultHmacKeyBytes(gpa);
    defer gpa.free(key);
    const sig = try license.license_file.signPayloadHex(gpa, payload, key);
    defer gpa.free(sig);
    const envelope = license.LicenseEnvelope{
        .payload = try payload.clone(gpa),
        .sig = try gpa.dupe(u8, sig),
    };
    defer {
        var owned = envelope;
        owned.deinit(gpa);
    }
    const json_bytes = try license.license_file.envelopeJsonAlloc(gpa, envelope);
    defer gpa.free(json_bytes);
    try std.fs.cwd().writeFile(.{ .sub_path = resolved_out, .data = json_bytes });
}
