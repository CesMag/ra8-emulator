//! The live usbip bridge (RA8EMU-75 slice 4c): the socket side of a run,
//! advanced by `poll` at each board boundary so it never blocks the
//! firmware. It waits for the FS device to enumerate, binds 127.0.0.1,
//! accepts a host when one is knocking, and once a host has imported the
//! device it reads that host's URBs and pumps them through the pipes the
//! firmware opened. A host that hangs up leaves the listener open for
//! the next one. Nothing is printed here; the caller reports the events.
const std = @import("std");
const exp = @import("exported.zig");
const board = @import("board.zig");
const listen = @import("listen.zig");
const server = @import("server.zig");
const session = @import("session.zig");
const usbfs = @import("ra8_chip").periph.usbfs;
const sock_ready = @import("ra8_host").sock_ready;

/// What one poll changed.
pub const Event = enum { none, listening, attached, hung_up, unusable };

/// One accepted host: its stream with the reader and writer over it. Built
/// in place inside the bridge, so the interfaces never move, and kept from
/// the import phase into the URB phase so nothing buffered is lost.
const Conn = struct {
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    rbuf: [buffer_len]u8,
    wbuf: [buffer_len]u8,

    /// Room for a header and the largest URB's data.
    const buffer_len = 2 * session.max_length;
};

pub const Bridge = struct {
    io: std.Io,
    wanted: u16,
    live: *session.Session,
    exports: [1]exp.Export = undefined,
    listener: ?std.Io.net.Server = null,
    conn: ?Conn = null,
    given_up: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, wanted: u16) !Bridge {
        const live = try allocator.create(session.Session);
        live.* = .{};
        return .{ .io = io, .wanted = wanted, .live = live };
    }

    pub fn deinit(self: *Bridge, allocator: std.mem.Allocator) void {
        if (self.conn) |*conn| conn.stream.close(self.io);
        if (self.listener) |*listener| listener.deinit(self.io);
        allocator.destroy(self.live);
    }

    /// The port the listener is bound to, once it is.
    pub fn port(self: *const Bridge) ?u16 {
        const listener = self.listener orelse return null;
        return listener.socket.address.getPort();
    }

    /// The exported device, once there is one.
    pub fn exported(self: *const Bridge) ?*const exp.Export {
        return if (self.listener == null) null else &self.exports[0];
    }

    /// Advance whatever stage the bridge is in, without waiting.
    pub fn poll(self: *Bridge, device: *usbfs.Device, script: *const usbfs.host.Host) !Event {
        if (self.conn) |*conn| return self.traffic(conn, device);
        if (self.listener) |*listener| return self.accept(listener);
        if (self.given_up) return .none;
        return self.offer(script);
    }

    fn offer(self: *Bridge, script: *const usbfs.host.Host) !Event {
        const found = board.fsExport(script) catch {
            self.given_up = true;
            return .unusable;
        } orelse return .none;
        self.exports[0] = found;
        self.listener = try listen.open(self.io, self.wanted);
        return .listening;
    }

    fn accept(self: *Bridge, listener: *std.Io.net.Server) !Event {
        if (!readable(listener.socket.handle)) return .none;
        const conn = self.connect(try listener.accept(self.io));
        const imported = server.serve(&conn.reader.interface, &conn.writer.interface, &self.exports) catch null;
        if (imported == null) {
            _ = self.hangUp(conn);
            return .none;
        }
        return .attached;
    }

    fn connect(self: *Bridge, stream: std.Io.net.Stream) *Conn {
        self.conn = .{ .stream = stream, .reader = undefined, .writer = undefined, .rbuf = undefined, .wbuf = undefined };
        const conn = &self.conn.?;
        conn.reader = stream.reader(self.io, &conn.rbuf);
        conn.writer = stream.writer(self.io, &conn.wbuf);
        return conn;
    }

    fn traffic(self: *Bridge, conn: *Conn, device: *usbfs.Device) !Event {
        const reader = &conn.reader.interface;
        const writer = &conn.writer.interface;
        while (reader.bufferedLen() > 0 or readable(conn.stream.socket.handle)) {
            const more = self.live.receive(reader, writer) catch false;
            if (!more) return self.hangUp(conn);
        }
        _ = self.live.pump(device, writer) catch return self.hangUp(conn);
        writer.flush() catch return self.hangUp(conn);
        return .none;
    }

    fn hangUp(self: *Bridge, conn: *Conn) Event {
        conn.stream.close(self.io);
        self.conn = null;
        self.live.* = .{};
        return .hung_up;
    }
};

/// A read will not block: bytes waiting or the peer hung up.
fn readable(handle: std.posix.socket_t) bool {
    const ready = sock_ready.wait(handle, 0) catch return false;
    return ready.any();
}
