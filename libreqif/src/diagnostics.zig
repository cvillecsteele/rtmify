const std = @import("std");

pub const DiagnosticSeverity = enum {
    warning,
    @"error",
};

pub const Diagnostic = struct {
    severity: DiagnosticSeverity,
    context_identifier: ?[]const u8 = null,
    message: []const u8,
};

pub const Collector = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Diagnostic) = .empty,

    pub fn init(allocator: std.mem.Allocator) Collector {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Collector) void {
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn add(
        self: *Collector,
        severity: DiagnosticSeverity,
        context_identifier: ?[]const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const message = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.items.append(self.allocator, .{
            .severity = severity,
            .context_identifier = context_identifier,
            .message = message,
        });
    }

    pub fn warn(
        self: *Collector,
        context_identifier: ?[]const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        try self.add(.warning, context_identifier, fmt, args);
    }

    pub fn err(
        self: *Collector,
        context_identifier: ?[]const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        try self.add(.@"error", context_identifier, fmt, args);
    }

    pub fn toOwnedSlice(self: *Collector) ![]const Diagnostic {
        return self.items.toOwnedSlice(self.allocator);
    }
};
