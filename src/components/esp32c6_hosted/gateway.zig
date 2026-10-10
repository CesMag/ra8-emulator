//! The access point's gateway, as the C6 station sees it.
//!
//! After the DHCP lease the firmware pings its gateway to prove the link
//! carries traffic. The model answers for 192.168.4.1 (the DHCP server's
//! address) the way the bench AP does: ARP requests for it get the BSSID,
//! and ICMP echo requests to it get an echo reply with the same payload.
const std = @import("std");
const eth = @import("eth.zig");
const dhcp = @import("dhcp.zig");
const frame = @import("frame.zig");
const station = @import("station.zig");

pub const ethertype_arp: u16 = 0x0806;
pub const arp_len: usize = 28;
pub const proto_icmp: u8 = 1;
pub const echo_request: u8 = 8;
pub const echo_reply: u8 = 0;
pub const gateway_ip = dhcp.server_ip;

/// Builds the sta frame the gateway sends back for Ethernet frame
/// `ethernet`; false when the gateway does not answer it.
pub fn answerFrame(out: *[frame.frame_size]u8, ethernet: []const u8) bool {
    if (ethernet.len < eth.eth_header) return false;
    var buf: [frame.max_payload]u8 = undefined;
    const len = switch (be16(ethernet[12..14])) {
        ethertype_arp => arpReply(&buf, ethernet),
        eth.ethertype_ipv4 => echoReply(&buf, ethernet),
        else => null,
    } orelse return false;
    frame.build(out, .{ .interface = .sta, .if_num = 0 }, buf[0..len]) catch return false;
    return true;
}

/// The ARP reply for a request asking who has the gateway address.
pub fn arpReply(out: []u8, ethernet: []const u8) ?usize {
    if (ethernet.len < eth.eth_header + arp_len) return null;
    const req = ethernet[eth.eth_header..][0..arp_len];
    if (be16(req[0..2]) != 1 or be16(req[2..4]) != eth.ethertype_ipv4) return null;
    if (req[4] != 6 or req[5] != 4 or be16(req[6..8]) != 1) return null;
    if (!std.mem.eql(u8, req[24..28], &gateway_ip)) return null;
    const len = eth.eth_header + arp_len;
    if (out.len < len) return null;
    @memcpy(out[0..6], req[8..14]);
    @memcpy(out[6..12], &station.bssid);
    std.mem.writeInt(u16, out[12..14], ethertype_arp, .big);
    const rep = out[eth.eth_header..][0..arp_len];
    @memcpy(rep[0..6], req[0..6]);
    std.mem.writeInt(u16, rep[6..8], 2, .big);
    @memcpy(rep[8..14], &station.bssid);
    @memcpy(rep[14..18], &gateway_ip);
    @memcpy(rep[18..24], req[8..14]);
    @memcpy(rep[24..28], req[14..18]);
    return len;
}

/// The echo reply for an ICMP echo request addressed to the gateway.
pub fn echoReply(out: []u8, ethernet: []const u8) ?usize {
    if (ethernet.len < eth.eth_header + eth.ip_header) return null;
    const ip = ethernet[eth.eth_header..];
    if (ip[0] >> 4 != 4 or ip[9] != proto_icmp) return null;
    if (!std.mem.eql(u8, ip[16..20], &gateway_ip)) return null;
    const ihl: usize = @as(usize, ip[0] & 0xF) * 4;
    const total: usize = be16(ip[2..4]);
    if (ihl < eth.ip_header or total < ihl + 8 or total > ip.len) return null;
    if (ip[ihl] != echo_request) return null;
    const len = eth.eth_header + total;
    if (out.len < len) return null;
    @memcpy(out[0..len], ethernet[0..len]);
    @memcpy(out[0..6], ethernet[6..12]);
    @memcpy(out[6..12], &station.bssid);
    const rip = out[eth.eth_header..][0..total];
    @memcpy(rip[12..16], ip[16..20]);
    @memcpy(rip[16..20], ip[12..16]);
    rip[8] = 64;
    std.mem.writeInt(u16, rip[10..12], 0, .big);
    std.mem.writeInt(u16, rip[10..12], eth.fold(eth.sum(0, rip[0..ihl])), .big);
    const icmp = rip[ihl..total];
    icmp[0] = echo_reply;
    std.mem.writeInt(u16, icmp[2..4], 0, .big);
    std.mem.writeInt(u16, icmp[2..4], eth.fold(eth.sum(0, icmp)), .big);
    return len;
}

fn be16(bytes: *const [2]u8) u16 {
    return std.mem.readInt(u16, bytes, .big);
}
