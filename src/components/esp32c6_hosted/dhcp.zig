//! The access point's DHCP server, as the C6 station sees it.
//!
//! The bench AP leases the board an address once it joins. The model plays
//! that server on the sta interface: a DISCOVER gets an OFFER and a REQUEST
//! gets an ACK, both broadcast from the AP (the station's BSSID) with one
//! fixed lease, so a run needs no host network.
const std = @import("std");
const eth = @import("eth.zig");
const frame = @import("frame.zig");
const station = @import("station.zig");

pub const server_port: u16 = 67;
pub const client_port: u16 = 68;
pub const server_ip = [4]u8{ 192, 168, 4, 1 };
pub const lease_ip = [4]u8{ 192, 168, 4, 2 };
pub const netmask = [4]u8{ 255, 255, 255, 0 };
pub const lease_seconds: u32 = 3600;
pub const cookie = [4]u8{ 0x63, 0x82, 0x53, 0x63 };
/// Offset of the options field in a BOOTP message.
pub const options_at: usize = 240;
/// BOOTP's minimum message size; replies are padded to it.
pub const reply_len: usize = 300;

pub const MessageType = enum(u8) { discover = 1, offer = 2, request = 3, ack = 5, nak = 6, _ };

/// The DHCP message type (option 53) of `data`, or null when it has none.
pub fn messageType(data: []const u8) ?MessageType {
    if (data.len < options_at + 3) return null;
    if (!std.mem.eql(u8, data[236..240], &cookie)) return null;
    var i: usize = options_at;
    while (i < data.len) {
        const code = data[i];
        if (code == 255) return null;
        if (code == 0) {
            i += 1;
            continue;
        }
        if (i + 2 >= data.len) return null;
        const len = data[i + 1];
        if (code == 53 and len == 1) return @fromBackingInt(@intCast(data[i + 2]));
        i += 2 + @as(usize, len);
    }
    return null;
}

/// The server's answer to a client message, or null when it gets none.
pub fn answerTo(kind: MessageType) ?MessageType {
    return switch (kind) {
        .discover => .offer,
        .request => .ack,
        else => null,
    };
}

/// Writes the `kind` reply to client message `request` into out[0..reply_len].
pub fn reply(out: []u8, request: []const u8, kind: MessageType) void {
    @memset(out[0..reply_len], 0);
    out[0] = 2;
    out[1] = 1;
    out[2] = 6;
    @memcpy(out[4..8], request[4..8]);
    @memcpy(out[10..12], request[10..12]);
    @memcpy(out[16..20], &lease_ip);
    @memcpy(out[20..24], &server_ip);
    @memcpy(out[28..44], request[28..44]);
    @memcpy(out[236..240], &cookie);
    var lease: [4]u8 = undefined;
    std.mem.writeInt(u32, &lease, lease_seconds, .big);
    var at = option(out, options_at, 53, &.{@backingInt(kind)});
    at = option(out, at, 54, &server_ip);
    at = option(out, at, 51, &lease);
    at = option(out, at, 1, &netmask);
    at = option(out, at, 3, &server_ip);
    at = option(out, at, 6, &server_ip);
    out[at] = 255;
}

fn option(out: []u8, at: usize, code: u8, value: []const u8) usize {
    out[at] = code;
    out[at + 1] = @intCast(value.len);
    @memcpy(out[at + 2 ..][0..value.len], value);
    return at + 2 + value.len;
}

/// Builds the sta frame answering the DHCP client message in Ethernet frame
/// `ethernet`; false when it is not one the server answers.
pub fn answerFrame(out: *[frame.frame_size]u8, ethernet: []const u8) bool {
    const dgram = eth.udp(ethernet) orelse return false;
    if (dgram.dst_port != server_port or dgram.data.len < options_at) return false;
    if (dgram.data[0] != 1) return false;
    const kind = answerTo(messageType(dgram.data) orelse return false) orelse return false;
    var buf: [eth.headers + reply_len]u8 = undefined;
    reply(buf[eth.headers..], dgram.data, kind);
    const len = eth.wrap(&buf, .{
        .src_mac = station.bssid,
        .dst_mac = @splat(0xFF),
        .src_ip = server_ip,
        .dst_ip = @splat(0xFF),
        .src_port = server_port,
        .dst_port = client_port,
    }, reply_len);
    frame.build(out, .{ .interface = .sta, .if_num = 0 }, buf[0..len]) catch return false;
    return true;
}
