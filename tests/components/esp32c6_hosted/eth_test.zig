//! Tests for src/components/esp32c6_hosted/eth.zig.
const std = @import("std");
const ra8 = @import("ra8");
const eth = ra8.components.esp_hosted.eth;

const route: eth.Route = .{
    .src_mac = .{ 1, 2, 3, 4, 5, 6 },
    .dst_mac = @splat(0xFF),
    .src_ip = .{ 10, 0, 0, 1 },
    .dst_ip = .{ 10, 0, 0, 2 },
    .src_port = 68,
    .dst_port = 67,
};

fn sample(buf: []u8) usize {
    @memcpy(buf[eth.headers..][0..5], "hello");
    return eth.wrap(buf, route, 5);
}

test "a wrapped datagram reads back with its ports and payload" {
    var buf: [64]u8 = undefined;
    const len = sample(&buf);
    try std.testing.expectEqual(eth.headers + 5, len);
    const got = eth.udp(buf[0..len]).?;
    try std.testing.expectEqual(@as(u16, 68), got.src_port);
    try std.testing.expectEqual(@as(u16, 67), got.dst_port);
    try std.testing.expectEqualSlices(u8, "hello", got.data);
}

test "the IPv4 header checksum verifies" {
    var buf: [64]u8 = undefined;
    _ = sample(&buf);
    const ip = buf[eth.eth_header..][0..eth.ip_header];
    try std.testing.expectEqual(@as(u16, 0), eth.fold(eth.sum(0, ip)));
}

test "the UDP checksum verifies over the pseudo header" {
    var buf: [64]u8 = undefined;
    const len = sample(&buf);
    const datagram = buf[eth.eth_header + eth.ip_header .. len];
    var acc = eth.sum(0, &route.src_ip);
    acc = eth.sum(acc, &route.dst_ip);
    acc += eth.proto_udp + @as(u32, @intCast(datagram.len));
    try std.testing.expectEqual(@as(u16, 0), eth.fold(eth.sum(acc, datagram)));
}

test "frames that are not UDP over IPv4 are not read" {
    var buf: [64]u8 = undefined;
    const len = sample(&buf);
    var arp = buf;
    arp[12] = 0x08;
    arp[13] = 0x06;
    try std.testing.expect(eth.udp(arp[0..len]) == null);
    var tcp = buf;
    tcp[eth.eth_header + 9] = 6;
    try std.testing.expect(eth.udp(tcp[0..len]) == null);
    try std.testing.expect(eth.udp(buf[0..20]) == null);
}

test "TCP frames round-trip fields and checksums" {
    var buf: [ra8.components.esp_hosted.frame.max_payload]u8 = undefined;
    const len = eth.tcpFrame(
        &buf,
        route,
        0x10203040,
        0x50607080,
        eth.TcpFlag.syn | eth.TcpFlag.ack,
        1460,
        "hello",
    ).?;
    const ip = eth.ipv4(buf[0..len]).?;
    const segment = eth.tcp(ip).?;
    try std.testing.expectEqual(@as(u32, 0x10203040), segment.seq);
    try std.testing.expectEqual(@as(u32, 0x50607080), segment.ack);
    try std.testing.expectEqual(eth.TcpFlag.syn | eth.TcpFlag.ack, segment.flags);
    try std.testing.expectEqual(@as(u16, 1460), segment.window);
    try std.testing.expectEqualSlices(u8, "hello", segment.data);
}

test "bad checksums fragments and oversize payloads are refused" {
    var buf: [ra8.components.esp_hosted.frame.max_payload]u8 = undefined;
    const len = eth.tcpFrame(&buf, route, 1, 2, eth.TcpFlag.ack, 4, "x").?;
    var bad_ip = buf;
    bad_ip[eth.eth_header + 10] ^= 1;
    try std.testing.expect(eth.ipv4(bad_ip[0..len]) == null);
    var fragment = buf;
    fragment[eth.eth_header + 6] = 0x20;
    try std.testing.expect(eth.ipv4(fragment[0..len]) == null);
    var bad_tcp = buf;
    bad_tcp[len - 1] ^= 1;
    try std.testing.expect(eth.tcp(eth.ipv4(bad_tcp[0..len]).?) == null);
    const too_big = @as([eth.tcp_payload_max + 1]u8, @splat(0));
    try std.testing.expect(eth.tcpFrame(&buf, route, 0, 0, 0, 0, &too_big) == null);
}

test "a zero UDP checksum is accepted" {
    var buf: [64]u8 = undefined;
    const len = sample(&buf);
    buf[eth.eth_header + eth.ip_header + 6] = 0;
    buf[eth.eth_header + eth.ip_header + 7] = 0;
    try std.testing.expectEqualSlices(u8, "hello", eth.udp(buf[0..len]).?.data);
}
