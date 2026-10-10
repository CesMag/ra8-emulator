//! Tests for src/components/esp32c6_hosted/dhcp.zig.
const std = @import("std");
const ra8 = @import("ra8");
const hosted = ra8.components.esp_hosted;
const frame = hosted.frame;
const eth = hosted.eth;
const dhcp = hosted.dhcp;
const Link = hosted.link.Link;

const client_mac = [6]u8{ 9, 8, 7, 6, 5, 4 };

/// A client BOOTP message of `kind` with xid 0x12345678 and the broadcast flag.
fn clientMessage(buf: *[dhcp.reply_len]u8, kind: dhcp.MessageType) void {
    @memset(buf, 0);
    buf[0] = 1;
    buf[1] = 1;
    buf[2] = 6;
    @memcpy(buf[4..8], &[_]u8{ 0x12, 0x34, 0x56, 0x78 });
    buf[10] = 0x80;
    @memcpy(buf[28..34], &client_mac);
    @memcpy(buf[236..240], &dhcp.cookie);
    @memcpy(buf[240..244], &[_]u8{ 53, 1, @backingInt(kind), 255 });
}

/// The Ethernet frame the station broadcasts for client message `kind`.
fn clientFrame(buf: []u8, kind: dhcp.MessageType, port: u16) usize {
    clientMessage(buf[eth.headers..][0..dhcp.reply_len], kind);
    return eth.wrap(buf, .{
        .src_mac = client_mac,
        .dst_mac = @splat(0xFF),
        .src_ip = .{ 0, 0, 0, 0 },
        .dst_ip = @splat(0xFF),
        .src_port = dhcp.client_port,
        .dst_port = port,
    }, dhcp.reply_len);
}

/// Runs `kind` through answerFrame and returns the reply's BOOTP bytes.
fn answer(out: *[frame.frame_size]u8, kind: dhcp.MessageType) ![]const u8 {
    var buf: [eth.headers + dhcp.reply_len]u8 = undefined;
    const len = clientFrame(&buf, kind, dhcp.server_port);
    try std.testing.expect(dhcp.answerFrame(out, buf[0..len]));
    const got = try frame.parse(out);
    try std.testing.expectEqual(frame.Interface.sta, got.header.interface);
    try std.testing.expectEqualSlices(u8, &(@as([6]u8, @splat(0xFF))), got.payload[0..6]);
    const dgram = eth.udp(got.payload).?;
    try std.testing.expectEqual(dhcp.server_port, dgram.src_port);
    try std.testing.expectEqual(dhcp.client_port, dgram.dst_port);
    return dgram.data;
}

test "the message type is read from option 53" {
    var buf: [dhcp.reply_len]u8 = undefined;
    clientMessage(&buf, .discover);
    try std.testing.expectEqual(dhcp.MessageType.discover, dhcp.messageType(&buf).?);
    buf[236] = 0;
    try std.testing.expect(dhcp.messageType(&buf) == null);
}

test "a DISCOVER gets an OFFER of the fixed lease" {
    var out: [frame.frame_size]u8 = undefined;
    const data = try answer(&out, .discover);
    try std.testing.expectEqual(@as(u8, 2), data[0]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x34, 0x56, 0x78 }, data[4..8]);
    try std.testing.expectEqualSlices(u8, &dhcp.lease_ip, data[16..20]);
    try std.testing.expectEqualSlices(u8, &client_mac, data[28..34]);
    try std.testing.expectEqual(dhcp.MessageType.offer, dhcp.messageType(data).?);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 54, 4, 192, 168, 4, 1 }, data[243..249]);
}

test "a REQUEST gets an ACK" {
    var out: [frame.frame_size]u8 = undefined;
    const data = try answer(&out, .request);
    try std.testing.expectEqual(dhcp.MessageType.ack, dhcp.messageType(data).?);
}

test "other UDP traffic gets no answer" {
    var buf: [eth.headers + dhcp.reply_len]u8 = undefined;
    var out: [frame.frame_size]u8 = undefined;
    const len = clientFrame(&buf, .discover, 53);
    try std.testing.expect(!dhcp.answerFrame(&out, buf[0..len]));
    const ack_len = clientFrame(&buf, .ack, dhcp.server_port);
    try std.testing.expect(!dhcp.answerFrame(&out, buf[0..ack_len]));
}

test "the link queues the OFFER for a station DISCOVER" {
    var link: Link = .{ .caps_seen = true };
    var buf: [eth.headers + dhcp.reply_len]u8 = undefined;
    const len = clientFrame(&buf, .discover, dhcp.server_port);
    var sent: [frame.frame_size]u8 = undefined;
    var got: [frame.frame_size]u8 = undefined;
    try frame.build(&sent, .{ .interface = .sta }, buf[0..len]);
    for (sent, &got) |byte, *o| o.* = link.exchange(byte);
    try std.testing.expect(link.dataReady());
    frame.filler(&sent);
    for (sent, &got) |byte, *o| o.* = link.exchange(byte);
    const parsed = try frame.parse(&got);
    try std.testing.expectEqual(frame.Interface.sta, parsed.header.interface);
    const dgram = eth.udp(parsed.payload).?;
    try std.testing.expectEqual(dhcp.MessageType.offer, dhcp.messageType(dgram.data).?);
}
