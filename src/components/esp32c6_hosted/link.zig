//! The ESP32-C6 side of the esp-hosted SPI link, one frame at a time.
const frame = @import("frame.zig");
const event = @import("event.zig");
const rpc = @import("rpc.zig");
const station = @import("station.zig");
const dhcp = @import("dhcp.zig");
const gateway = @import("gateway.zig");
const net = @import("net.zig");
const Queue = @import("queue.zig").Queue;

/// Octets of the host capabilities announcement kept for inspection.
pub const caps_capacity: usize = 17;

pub const Link = struct {
    rx: [frame.frame_size]u8 = undefined,
    tx: [frame.frame_size]u8 = undefined,
    offset: u16 = 0,
    caps_seen: bool = false,
    caps: [caps_capacity]u8 = @splat(0),
    caps_len: u8 = 0,
    boot_queued: bool = false,
    boots_sent: u32 = 0,
    queue: Queue = .{},
    replies_sent: u32 = 0,
    bridge: net.Bridge = .{},

    /// Clocks one byte in from the host and returns the byte clocked out.
    pub fn exchange(self: *Link, byte: u8) u8 {
        if (self.offset == 0) self.load();
        const out = self.tx[self.offset];
        self.rx[self.offset] = byte;
        self.offset += 1;
        if (self.offset == frame.frame_size) {
            self.offset = 0;
            self.receive();
        }
        return out;
    }

    /// Polls live host sockets only after the esp-hosted boot handshake.
    pub fn poll(self: *Link) void {
        if (self.caps_seen) self.bridge.poll(&self.queue);
    }

    pub fn deinit(self: *Link) void {
        self.bridge.deinit();
    }
    pub fn networkActive(self: *const Link) bool {
        return self.bridge.active();
    }

    /// DATA_READY: high while the transmit queue holds a frame.
    pub fn dataReady(self: *const Link) bool {
        return self.boot_queued or !self.queue.isEmpty();
    }

    fn load(self: *Link) void {
        if (self.boot_queued) {
            self.boot_queued = false;
            if (event.espInitFrame(&self.tx, 0)) |_| {
                self.boots_sent += 1;
                return;
            } else |_| {}
        }
        if (self.queue.pop(&self.tx)) {
            self.replies_sent += 1;
            return;
        }
        frame.filler(&self.tx);
    }

    fn receive(self: *Link) void {
        const got = frame.parse(&self.rx) catch return;
        if (got.header.interface == .priv) self.announce(got.payload);
        if (got.header.interface == .serial) self.serve(got.payload);
        if (got.header.interface == .sta) self.forward(got.payload);
    }

    fn announce(self: *Link, payload: []const u8) void {
        self.caps_seen = true;
        const take = @min(payload.len, caps_capacity);
        @memcpy(self.caps[0..take], payload[0..take]);
        self.caps_len = @intCast(take);
        self.boot_queued = true;
    }

    /// Answers a known RPC request; none before the host has announced itself.
    fn serve(self: *Link, payload: []const u8) void {
        if (!self.caps_seen) return;
        const proto = rpc.tlvData(payload) orelse return;
        const req = rpc.request(proto) catch return;
        var out: [frame.frame_size]u8 = undefined;
        if (!(rpc.answerFrame(&out, req) catch false)) return;
        _ = self.queue.push(&out);
        const id = station.followUp(req.id) orelse return;
        station.eventFrame(&out, id) catch return;
        _ = self.queue.push(&out);
    }

    /// Answers synthetic link services first, then passes IP traffic to host sockets.
    fn forward(self: *Link, payload: []const u8) void {
        if (!self.caps_seen) return;
        var out: [frame.frame_size]u8 = undefined;
        if (dhcp.answerFrame(&out, payload) or gateway.answerFrame(&out, payload)) {
            _ = self.queue.push(&out);
            return;
        }
        _ = self.bridge.forward(&self.queue, payload);
    }
};
