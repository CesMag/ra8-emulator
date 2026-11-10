//! Auto-detecting RPC byte transport over connected TCP/Unix sockets and WebSockets (RA8EMU-1241).
//! Transparently detects HTTP GET `Upgrade: websocket` vs raw TCP RPC greetings.
const std = @import("std");
const rpc = @import("ra8_rpc_wire");
const sock_ready = @import("ra8_host").sock.ready;
const ws_handshake = @import("ws_handshake.zig");
const ws_frame = @import("ws_frame.zig");

pub const State = enum {
    detect,
    raw,
    websocket,
    closed,
};

pub const Connection = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    state: State = .detect,

    rx_buf: [4096]u8 = undefined,
    rx_start: usize = 0,
    rx_len: usize = 0,

    frame_remaining: usize = 0,
    frame_mask: [4]u8 = .{ 0, 0, 0, 0 },
    frame_mask_offset: usize = 0,

    pub fn fromFd(io: std.Io, fd: std.posix.fd_t) Connection {
        return .{ .stream = .{ .socket = .{ .handle = fd, .address = .{ .ip4 = .loopback(0) } } }, .io = io };
    }

    pub fn tcp(io: std.Io, address: std.Io.net.IpAddress) !Connection {
        return .{ .stream = try address.connect(io, .{ .mode = .stream }), .io = io };
    }

    pub fn unix(io: std.Io, path: []const u8) !Connection {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const name = try @import("ra8_host").sock.path.unix(io, path, &buffer);
        const address = try std.Io.net.UnixAddress.init(name);
        return .{ .stream = try address.connect(io), .io = io };
    }

    pub fn init(io: std.Io, stream: std.Io.net.Stream) Connection {
        return .{ .stream = stream, .io = io };
    }

    pub fn transport(self: *Connection) rpc.Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    pub fn close(self: *Connection) void {
        self.state = .closed;
        self.stream.close(self.io);
    }

    const vtable: rpc.Transport.VTable = .{
        .send = send,
        .receive = receive,
        .poll = poll,
    };

    fn from(ctx: *anyopaque) *Connection {
        return @ptrCast(@alignCast(ctx));
    }

    fn readSocket(self: *Connection, into: []u8) rpc.Transport.Error!usize {
        if (into.len == 0) return 0;
        const ready = sock_ready.wait(self.io, self.stream.socket.handle, 0) catch return error.LinkDown;
        if (!ready.any()) return 0;
        var vec = [_][]u8{into};
        const got = self.stream.readWithControl(self.io, &vec, &.{}) catch return error.LinkDown;
        return got.data_len;
    }

    fn send(ctx: *anyopaque, bytes: []const u8) rpc.Transport.Error!void {
        const self = from(ctx);
        switch (self.state) {
            .raw => {
                sock_ready.sendAll(self.io, self.stream.socket.handle, bytes, 100) catch return error.LinkDown;
            },
            .websocket => {
                if (bytes.len <= 2048) {
                    var packet: [2048 + 10]u8 = undefined;
                    const hdr = ws_frame.encodeServerHeader(&packet, .binary, bytes.len);
                    @memcpy(packet[hdr.len..][0..bytes.len], bytes);
                    sock_ready.sendAll(self.io, self.stream.socket.handle, packet[0 .. hdr.len + bytes.len], 100) catch return error.LinkDown;
                } else {
                    var hdr_buf: [10]u8 = undefined;
                    const hdr = ws_frame.encodeServerHeader(&hdr_buf, .binary, bytes.len);
                    sock_ready.sendAll(self.io, self.stream.socket.handle, hdr, 100) catch return error.LinkDown;
                    sock_ready.sendAll(self.io, self.stream.socket.handle, bytes, 100) catch return error.LinkDown;
                }
            },
            .detect => {
                self.state = .raw;
                sock_ready.sendAll(self.io, self.stream.socket.handle, bytes, 100) catch return error.LinkDown;
            },
            .closed => return error.LinkDown,
        }
    }

    fn receive(ctx: *anyopaque, into: []u8) rpc.Transport.Error!usize {
        const self = from(ctx);
        return switch (self.state) {
            .detect => self.detectAndReceive(into),
            .raw => self.drainRaw(into),
            .websocket => self.receiveWebsocket(into),
            .closed => error.LinkDown,
        };
    }

    fn poll(ctx: *anyopaque) usize {
        const self = from(ctx);
        switch (self.state) {
            .raw => {
                if (self.rx_len > 0) return self.rx_len;
                const ready = sock_ready.wait(self.io, self.stream.socket.handle, 0) catch return 0;
                return @intFromBool(ready.any());
            },
            .websocket => {
                if (self.frame_remaining > 0 and self.rx_len > 0) {
                    return @min(self.rx_len, self.frame_remaining);
                }
                if (self.rx_len > 0) return self.rx_len;
                const ready = sock_ready.wait(self.io, self.stream.socket.handle, 0) catch return 0;
                return @intFromBool(ready.any());
            },
            .detect => {
                if (self.rx_len > 0) return self.rx_len;
                const ready = sock_ready.wait(self.io, self.stream.socket.handle, 0) catch return 0;
                return @intFromBool(ready.any());
            },
            .closed => return 0,
        }
    }

    fn detectAndReceive(self: *Connection, into: []u8) rpc.Transport.Error!usize {
        const room = self.rx_buf.len - (self.rx_start + self.rx_len);
        if (room > 0) {
            const got = try self.readSocket(self.rx_buf[self.rx_start + self.rx_len ..]);
            self.rx_len += got;
        }
        if (self.rx_len == 0) return 0;

        const available = self.rx_buf[self.rx_start .. self.rx_start + self.rx_len];
        if (available[0] != 'G') {
            self.state = .raw;
            return self.drainRaw(into);
        }
        if (available.len < 4) return 0;
        if (!std.mem.startsWith(u8, available, "GET ")) {
            self.state = .raw;
            return self.drainRaw(into);
        }

        const end_idx = ws_handshake.findHeaderEnd(available) orelse {
            if (self.rx_len == self.rx_buf.len) return error.BadMessage;
            return 0;
        };

        const http_data = available[0..end_idx];
        try self.performHandshake(http_data);

        self.rx_start += end_idx;
        self.rx_len -= end_idx;
        self.state = .websocket;

        return self.receiveWebsocket(into);
    }

    fn performHandshake(self: *Connection, http_data: []const u8) rpc.Transport.Error!void {
        const req = ws_handshake.parseRequest(http_data) catch return error.BadMessage;
        if (!req.is_websocket) return error.BadMessage;

        var accept_key: [ws_handshake.accept_len]u8 = undefined;
        ws_handshake.computeAccept(req.key, &accept_key);

        var resp_buf: [ws_handshake.response_buf_size]u8 = undefined;
        const resp = ws_handshake.formatResponse(&accept_key, &resp_buf) catch return error.BadMessage;

        sock_ready.sendAll(self.io, self.stream.socket.handle, resp, 1000) catch return error.LinkDown;
    }

    fn drainRaw(self: *Connection, into: []u8) rpc.Transport.Error!usize {
        if (self.rx_len > 0) {
            const to_copy = @min(self.rx_len, into.len);
            @memcpy(into[0..to_copy], self.rx_buf[self.rx_start .. self.rx_start + to_copy]);
            self.rx_start += to_copy;
            self.rx_len -= to_copy;
            if (self.rx_len == 0) self.rx_start = 0;
            return to_copy;
        }
        return self.readSocket(into);
    }

    fn receiveWebsocket(self: *Connection, into: []u8) rpc.Transport.Error!usize {
        while (true) {
            if (self.frame_remaining > 0) {
                return self.deliverPayload(into);
            }

            self.compactRx();
            const room = self.rx_buf.len - self.rx_len;
            if (room > 0) {
                const got = try self.readSocket(self.rx_buf[self.rx_len..]);
                self.rx_len += got;
            }
            if (self.rx_len == 0) return 0;

            const available = self.rx_buf[0..self.rx_len];
            const hdr = (ws_frame.parseHeader(available) catch return error.BadMessage) orelse return 0;

            switch (hdr.opcode) {
                .binary => {
                    if (!hdr.masked) return error.BadMessage;
                    self.frame_remaining = hdr.payload_len;
                    self.frame_mask = hdr.mask;
                    self.frame_mask_offset = 0;
                    self.rx_start = hdr.header_len;
                    self.rx_len -= hdr.header_len;
                    return self.deliverPayload(into);
                },
                .ping => {
                    const total_len = hdr.header_len + hdr.payload_len;
                    if (available.len < total_len) return 0;
                    var ping_payload: [125]u8 = undefined;
                    @memcpy(ping_payload[0..hdr.payload_len], available[hdr.header_len..total_len]);
                    if (hdr.masked) {
                        ws_frame.unmask(ping_payload[0..hdr.payload_len], hdr.mask);
                    }
                    try self.sendPong(ping_payload[0..hdr.payload_len]);
                    self.rx_start = total_len;
                    self.rx_len -= total_len;
                },
                .pong => {
                    const total_len = hdr.header_len + hdr.payload_len;
                    if (available.len < total_len) return 0;
                    self.rx_start = total_len;
                    self.rx_len -= total_len;
                },
                .close => {
                    var close_hdr: [10]u8 = undefined;
                    const close_bytes = ws_frame.encodeServerHeader(&close_hdr, .close, 0);
                    sock_ready.sendAll(self.io, self.stream.socket.handle, close_bytes, 100) catch {};
                    self.state = .closed;
                    return error.LinkDown;
                },
                else => return error.BadMessage,
            }
        }
    }

    fn deliverPayload(self: *Connection, into: []u8) rpc.Transport.Error!usize {
        if (into.len == 0 or self.frame_remaining == 0) return 0;
        if (self.rx_len > 0) {
            const to_take = @min(@min(self.rx_len, self.frame_remaining), into.len);
            for (0..to_take) |i| {
                into[i] = self.rx_buf[self.rx_start + i] ^ self.frame_mask[(self.frame_mask_offset + i) % 4];
            }
            self.rx_start += to_take;
            self.rx_len -= to_take;
            self.frame_remaining -= to_take;
            self.frame_mask_offset += to_take;
            if (self.rx_len == 0) self.rx_start = 0;
            return to_take;
        }

        const to_read = @min(self.frame_remaining, into.len);
        const got = try self.readSocket(into[0..to_read]);
        if (got == 0) return 0;
        for (0..got) |i| {
            into[i] ^= self.frame_mask[(self.frame_mask_offset + i) % 4];
        }
        self.frame_remaining -= got;
        self.frame_mask_offset += got;
        return got;
    }

    fn sendPong(self: *Connection, payload: []const u8) rpc.Transport.Error!void {
        var packet: [135]u8 = undefined;
        const hdr = ws_frame.encodeServerHeader(&packet, .pong, payload.len);
        if (payload.len > 0) {
            @memcpy(packet[hdr.len..][0..payload.len], payload);
        }
        sock_ready.sendAll(self.io, self.stream.socket.handle, packet[0 .. hdr.len + payload.len], 100) catch return error.LinkDown;
    }

    fn compactRx(self: *Connection) void {
        if (self.rx_start > 0 and self.rx_len > 0) {
            std.mem.copyForwards(u8, self.rx_buf[0..self.rx_len], self.rx_buf[self.rx_start .. self.rx_start + self.rx_len]);
            self.rx_start = 0;
        } else if (self.rx_len == 0) {
            self.rx_start = 0;
        }
    }
};
