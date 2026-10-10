//! One host socket behind the C6 bridge: live, live and recorded, or
//! replayed from a tape with no host socket at all (RA8EMU-560).
const std = @import("std");
const tape = @import("esp_tape.zig");
const host_net = @import("esp_host_net.zig");

pub const Address = host_net.Address;
pub const Connect = host_net.Connect;

pub const Sock = struct {
    /// The host network the socket was opened on, and the socket.
    net: ?host_net.Net = null,
    socket: ?host_net.Handle = null,
    writer: ?tape.Writer = null,
    reader: ?tape.Reader = null,
    datagram: bool = false,

    /// Opens a nonblocking socket on `net` to `address` (replay opens the
    /// tape instead and needs no host network).
    pub fn connect(self: *Sock, run: *tape.Tape, net: ?host_net.Net, key: tape.Key, address: Address) !Connect {
        self.datagram = key.proto == .udp;
        if (run.mode == .replay) {
            self.reader = try run.load(key);
            return .done;
        }
        const host = net orelse return error.NoHostNetwork;
        self.net = host;
        self.socket = try host.open(if (key.proto == .tcp) .stream else .datagram);
        errdefer self.close();
        if (run.mode == .record) self.writer = try run.create(key);
        return host.connect(self.socket.?, address);
    }

    /// True once a pending connect has finished; an error means it failed.
    pub fn ready(self: *Sock) !bool {
        if (self.reader != null) return true;
        if (!try self.net.?.writable(self.socket.?)) return false;
        try self.net.?.finished(self.socket.?);
        return true;
    }

    /// Sends guest bytes; a replay checks them against the tape instead.
    pub fn send(self: *Sock, bytes: []const u8) !usize {
        if (self.reader) |*reader| {
            if (!reader.expect(bytes)) return error.ReplayDiverged;
            return bytes.len;
        }
        const sent = try self.net.?.send(self.socket.?, bytes);
        if (self.writer) |*writer| writer.put(.guest, bytes[0..sent]);
        return sent;
    }

    /// Receives host bytes; 0 is the host's close. A replay answers only
    /// once the guest has sent everything recorded before the answer.
    pub fn recv(self: *Sock, out: []u8, how: host_net.Receive) !usize {
        if (self.reader) |*reader| {
            const got = reader.take(out);
            if (got != 0 or (reader.closed() and !self.datagram)) return got;
            return error.WouldBlock;
        }
        const got = try self.net.?.recv(self.socket.?, out, how);
        if (self.writer) |*writer| {
            const dir: tape.Dir = if (got == 0 and !self.datagram) .closed else .host;
            writer.put(dir, out[0..@min(got, out.len)]);
        }
        return got;
    }

    pub fn shutdownSend(self: *Sock) !void {
        if (self.reader == null) try self.net.?.shutdownSend(self.socket.?);
    }

    pub fn close(self: *Sock) void {
        if (self.socket) |socket| self.net.?.close(socket);
        if (self.writer) |*writer| writer.close();
        if (self.reader) |*reader| reader.deinit();
        self.* = .{};
    }
};
