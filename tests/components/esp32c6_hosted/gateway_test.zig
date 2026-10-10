//! Tests for src/components/esp32c6_hosted/gateway.zig.
const std = @import("std");
const ra8 = @import("ra8");
const hosted = ra8.components.esp_hosted;
const frame = hosted.frame;
const eth = hosted.eth;
const gateway = hosted.gateway;
const station = hosted.station;

const client_mac = [6]u8{ 9, 8, 7, 6, 5, 4 };
const client_ip = [4]u8{ 192, 168, 4, 2 };
const payload = "ra8-c6-ping";

/// An ARP request from the station asking who has `target`.
fn arpRequest(buf: *[eth.eth_header + gateway.arp_len]u8, target: [4]u8) void {
    @memset(buf, 0);
    @memset(buf[0..6], 0xFF);
    @memcpy(buf[6..12], &client_mac);
    std.mem.writeInt(u16, buf[12..14], gateway.ethertype_arp, .big);
    const a = buf[eth.eth_header..];
    @memcpy(a[0..8], &[_]u8{ 0, 1, 8, 0, 6, 4, 0, 1 });
    @memcpy(a[8..14], &client_mac);
    @memcpy(a[14..18], &client_ip);
    @memcpy(a[24..28], &target);
}

const echo_len = eth.eth_header + eth.ip_header + 8 + payload.len;

/// An ICMP echo request from the station to `target`, id 0x0102 seq 3.
fn echoRequest(buf: *[echo_len]u8, target: [4]u8) void {
    @memcpy(buf[0..6], &station.bssid);
    @memcpy(buf[6..12], &client_mac);
    std.mem.writeInt(u16, buf[12..14], eth.ethertype_ipv4, .big);
    const ip = buf[eth.eth_header..];
    @memset(ip[0..eth.ip_header], 0);
    ip[0] = 0x45;
    std.mem.writeInt(u16, ip[2..4], @intCast(ip.len), .big);
    ip[8] = 128;
    ip[9] = gateway.proto_icmp;
    @memcpy(ip[12..16], &client_ip);
    @memcpy(ip[16..20], &target);
    std.mem.writeInt(u16, ip[10..12], eth.fold(eth.sum(0, ip[0..eth.ip_header])), .big);
    const icmp = ip[eth.ip_header..];
    @memcpy(icmp[0..8], &[_]u8{ gateway.echo_request, 0, 0, 0, 1, 2, 0, 3 });
    @memcpy(icmp[8..], payload);
    std.mem.writeInt(u16, icmp[2..4], eth.fold(eth.sum(0, icmp)), .big);
}

test "an ARP request for the gateway gets the BSSID" {
    var req: [eth.eth_header + gateway.arp_len]u8 = undefined;
    arpRequest(&req, gateway.gateway_ip);
    var out: [frame.frame_size]u8 = undefined;
    try std.testing.expect(gateway.answerFrame(&out, &req));
    const got = try frame.parse(&out);
    try std.testing.expectEqual(frame.Interface.sta, got.header.interface);
    const p = got.payload;
    try std.testing.expectEqualSlices(u8, &client_mac, p[0..6]);
    try std.testing.expectEqualSlices(u8, &station.bssid, p[6..12]);
    const a = p[eth.eth_header..];
    try std.testing.expectEqual(@as(u8, 2), a[7]);
    try std.testing.expectEqualSlices(u8, &station.bssid, a[8..14]);
    try std.testing.expectEqualSlices(u8, &gateway.gateway_ip, a[14..18]);
    try std.testing.expectEqualSlices(u8, &client_mac, a[18..24]);
    try std.testing.expectEqualSlices(u8, &client_ip, a[24..28]);
}

test "an ARP probe for another address gets no answer" {
    var req: [eth.eth_header + gateway.arp_len]u8 = undefined;
    arpRequest(&req, client_ip);
    var out: [frame.frame_size]u8 = undefined;
    try std.testing.expect(!gateway.answerFrame(&out, &req));
}

test "a ping to the gateway gets an echo reply with valid checksums" {
    var req: [echo_len]u8 = undefined;
    echoRequest(&req, gateway.gateway_ip);
    var out: [frame.frame_size]u8 = undefined;
    try std.testing.expect(gateway.answerFrame(&out, &req));
    const got = try frame.parse(&out);
    const p = got.payload;
    try std.testing.expectEqual(@as(usize, echo_len), p.len);
    try std.testing.expectEqualSlices(u8, &client_mac, p[0..6]);
    try std.testing.expectEqualSlices(u8, &station.bssid, p[6..12]);
    const ip = p[eth.eth_header..];
    try std.testing.expectEqualSlices(u8, &gateway.gateway_ip, ip[12..16]);
    try std.testing.expectEqualSlices(u8, &client_ip, ip[16..20]);
    try std.testing.expectEqual(@as(u16, 0), eth.fold(eth.sum(0, ip[0..eth.ip_header])));
    const icmp = ip[eth.ip_header..];
    try std.testing.expectEqual(gateway.echo_reply, icmp[0]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 0, 3 }, icmp[4..8]);
    try std.testing.expectEqualSlices(u8, payload, icmp[8..]);
    try std.testing.expectEqual(@as(u16, 0), eth.fold(eth.sum(0, icmp)));
}

test "a ping to another host gets no answer" {
    var req: [echo_len]u8 = undefined;
    echoRequest(&req, .{ 8, 8, 8, 8 });
    var out: [frame.frame_size]u8 = undefined;
    try std.testing.expect(!gateway.answerFrame(&out, &req));
}
