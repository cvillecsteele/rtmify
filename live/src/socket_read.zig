const std = @import("std");
const builtin = @import("builtin");

const windows = std.os.windows;
const ws2_32 = windows.ws2_32;

pub const ReadError = std.net.Stream.ReadError;

/// Windows-safe raw socket read for direct std.net.Stream users.
///
/// Use this only for raw socket protocols. For buffered or protocol-aware code,
/// prefer `stream.reader(...)`, `std.http.Client`, and `std.http.Server`; in
/// Zig 0.15.2 those already use WSARecv on Windows.
///
/// Avoid `std.net.Stream.read*` directly in application code. The deprecated
/// Windows implementation goes through ReadFile on the socket handle, which can
/// surface unmapped Win32 error codes as `error.Unexpected`.
pub fn read(stream: std.net.Stream, buffer: []u8, windows_error: ?*ws2_32.WinsockError) ReadError!usize {
    if (builtin.os.tag != .windows) {
        return stream.read(buffer);
    }

    const n = ws2_32.recv(stream.handle, buffer.ptr, @intCast(buffer.len), 0);
    if (n == ws2_32.SOCKET_ERROR) {
        const err = ws2_32.WSAGetLastError();
        if (windows_error) |out| out.* = err;
        return mapWindowsRecvError(err);
    }
    return @intCast(n);
}

pub fn readAtLeast(stream: std.net.Stream, buffer: []u8, len: usize, windows_error: ?*ws2_32.WinsockError) ReadError!usize {
    std.debug.assert(len <= buffer.len);

    var index: usize = 0;
    while (index < len) {
        const amt = try read(stream, buffer[index..], windows_error);
        if (amt == 0) break;
        index += amt;
    }
    return index;
}

fn mapWindowsRecvError(err: ws2_32.WinsockError) ReadError {
    return switch (err) {
        .WSAECONNRESET => error.ConnectionResetByPeer,
        .WSAEFAULT => unreachable,
        .WSAEINPROGRESS, .WSAEINTR => unreachable,
        .WSAEINVAL => error.SocketNotBound,
        .WSAEMSGSIZE => error.MessageTooBig,
        .WSAENETDOWN => error.NetworkSubsystemFailed,
        .WSAENETRESET => error.ConnectionResetByPeer,
        .WSAENOTCONN => error.SocketNotConnected,
        .WSAEWOULDBLOCK => error.WouldBlock,
        .WSANOTINITIALISED => unreachable,
        .WSA_IO_PENDING => unreachable,
        .WSA_OPERATION_ABORTED => unreachable,
        else => windows.unexpectedWSAError(err),
    };
}

fn acceptAndWrite(server: *std.net.Server) !void {
    const conn = try server.accept();
    defer conn.stream.close();
    try conn.stream.writeAll("hello");
}

test "readAtLeast reads from a loopback socket" {
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    const thread = try std.Thread.spawn(.{}, acceptAndWrite, .{&server});
    defer thread.join();

    const port = server.listen_address.getPort();
    const server_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    var stream = try std.net.tcpConnectToAddress(server_addr);
    defer stream.close();

    var buf: [5]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), try readAtLeast(stream, &buf, buf.len, null));
    try std.testing.expectEqualStrings("hello", &buf);
}
