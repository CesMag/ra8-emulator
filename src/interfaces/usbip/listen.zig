//! The usbip socket (RA8EMU-75 slice 3b): accept hosts on a loopback TCP
//! port and run the operation phase on each until one imports a device.
//! A host lists on one connection and imports on the next, so a listing
//! closes its connection and the next accept follows.
const std = @import("std");
const exp = @import("exported.zig");
const server = @import("server.zig");

/// The port usbip hosts dial by default.
pub const default_port: u16 = 3240;

/// A host that imported an export. URB traffic follows on `stream`.
pub const Attached = struct {
    stream: std.Io.net.Stream,
    item: *const exp.Export,
};

/// Bind 127.0.0.1:`wanted`. Port 0 lets the system pick; read it back from
/// `port`.
pub fn open(io: std.Io, wanted: u16) !std.Io.net.Server {
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(wanted) };
    return address.listen(io, .{ .reuse_address = true });
}

/// The port a bound listener ended up on.
pub fn port(listener: *const std.Io.net.Server) u16 {
    return listener.socket.address.getPort();
}

/// Accept hosts until one imports an export. A connection that only
/// lists, asks for an unknown busid, or hangs up is closed and the next
/// one accepted. A malformed request also closes only that connection.
pub fn attach(io: std.Io, listener: *std.Io.net.Server, exports: []const exp.Export) !Attached {
    while (true) {
        const stream = try listener.accept(io);
        var rbuf: [256]u8 = undefined;
        var wbuf: [256]u8 = undefined;
        var reader = stream.reader(io, &rbuf);
        var writer = stream.writer(io, &wbuf);
        const imported = server.serve(&reader.interface, &writer.interface, exports) catch null;
        if (imported) |item| return .{ .stream = stream, .item = item };
        stream.close(io);
    }
}
