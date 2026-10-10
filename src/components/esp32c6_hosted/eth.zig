//! Ethernet II, IPv4, UDP and TCP framing for the C6 station data path.
const std = @import("std");
const frame = @import("frame.zig");

pub const eth_header: usize = 14;
pub const ip_header: usize = 20;
pub const udp_header: usize = 8;
pub const tcp_header: usize = 20;
/// Bytes before a UDP payload in a frame `wrap` writes.
pub const headers: usize = eth_header + ip_header + udp_header;
pub const tcp_headers: usize = eth_header + ip_header + tcp_header;
pub const ethertype_ipv4: u16 = 0x0800;
pub const proto_tcp: u8 = 6;
pub const proto_udp: u8 = 17;
pub const tcp_payload_max: usize = 1460;
pub const udp_payload_max: usize = 1472;

pub const TcpFlag = struct {
    pub const fin: u8 = 0x01;
    pub const syn: u8 = 0x02;
    pub const rst: u8 = 0x04;
    pub const psh: u8 = 0x08;
    pub const ack: u8 = 0x10;
};

/// A validated IPv4 packet read out of an Ethernet frame.
pub const Ipv4 = struct {
    src_mac: [6]u8,
    dst_mac: [6]u8,
    src_ip: [4]u8,
    dst_ip: [4]u8,
    protocol: u8,
    transport: []const u8,
};

/// The IPv4 packet an Ethernet frame carries, or null when it is malformed or fragmented.
pub fn ipv4(bytes: []const u8) ?Ipv4 {
    if (bytes.len < eth_header + ip_header) return null;
    if (be16(bytes[12..14]) != ethertype_ipv4) return null;
    const ip = bytes[eth_header..];
    if (ip[0] >> 4 != 4) return null;
    const header_len: usize = @as(usize, ip[0] & 0x0F) * 4;
    const total: usize = be16(ip[2..4]);
    if (header_len < ip_header or header_len > ip.len or total < header_len or total > ip.len) return null;
    const fragment = be16(ip[6..8]);
    if (fragment & 0x3FFF != 0) return null;
    if (fold(sum(0, ip[0..header_len])) != 0) return null;
    return .{
        .src_mac = bytes[6..12].*,
        .dst_mac = bytes[0..6].*,
        .src_ip = ip[12..16].*,
        .dst_ip = ip[16..20].*,
        .protocol = ip[9],
        .transport = ip[header_len..total],
    };
}

/// A UDP datagram read out of an Ethernet frame.
pub const Udp = struct { src_port: u16, dst_port: u16, data: []const u8 };

/// The UDP datagram an Ethernet frame carries, or null for anything else.
pub fn udp(bytes: []const u8) ?Udp {
    const ip = ipv4(bytes) orelse return null;
    if (ip.protocol != proto_udp or ip.transport.len < udp_header) return null;
    const len: usize = be16(ip.transport[4..6]);
    if (len < udp_header or len > ip.transport.len) return null;
    const datagram = ip.transport[0..len];
    const checksum = be16(datagram[6..8]);
    if (checksum != 0 and transportChecksum(ip.src_ip, ip.dst_ip, proto_udp, datagram) != 0) return null;
    return .{
        .src_port = be16(datagram[0..2]),
        .dst_port = be16(datagram[2..4]),
        .data = datagram[udp_header..],
    };
}

/// A TCP segment read out of a validated IPv4 packet.
pub const Tcp = struct {
    src_port: u16,
    dst_port: u16,
    seq: u32,
    ack: u32,
    flags: u8,
    window: u16,
    data: []const u8,
};

pub fn tcp(ip: Ipv4) ?Tcp {
    if (ip.protocol != proto_tcp or ip.transport.len < tcp_header) return null;
    const offset: usize = @as(usize, ip.transport[12] >> 4) * 4;
    if (offset < tcp_header or offset > ip.transport.len) return null;
    if (transportChecksum(ip.src_ip, ip.dst_ip, proto_tcp, ip.transport) != 0) return null;
    return .{
        .src_port = be16(ip.transport[0..2]),
        .dst_port = be16(ip.transport[2..4]),
        .seq = be32(ip.transport[4..8]),
        .ack = be32(ip.transport[8..12]),
        .flags = ip.transport[13],
        .window = be16(ip.transport[14..16]),
        .data = ip.transport[offset..],
    };
}

/// Addresses and ports for a datagram `wrap` frames.
pub const Route = struct {
    src_mac: [6]u8,
    dst_mac: [6]u8,
    src_ip: [4]u8,
    dst_ip: [4]u8,
    src_port: u16,
    dst_port: u16,
};

/// Writes the Ethernet, IPv4 and UDP headers in front of the `data_len`
/// payload already at out[headers..] and returns the frame length.
pub fn wrap(out: []u8, route: Route, data_len: usize) usize {
    const udp_len = udp_header + data_len;
    const ip_len = ip_header + udp_len;
    ethernetIp(out, route, ip_len, proto_udp);
    const datagram = out[eth_header + ip_header ..][0..udp_len];
    std.mem.writeInt(u16, datagram[0..2], route.src_port, .big);
    std.mem.writeInt(u16, datagram[2..4], route.dst_port, .big);
    std.mem.writeInt(u16, datagram[4..6], @intCast(udp_len), .big);
    std.mem.writeInt(u16, datagram[6..8], 0, .big);
    const checksum = transportChecksum(route.src_ip, route.dst_ip, proto_udp, datagram);
    std.mem.writeInt(u16, datagram[6..8], if (checksum == 0) 0xFFFF else checksum, .big);
    return eth_header + ip_len;
}

/// Copies one UDP payload and emits its raw Ethernet frame.
pub fn udpFrame(out: *[frame.max_payload]u8, route: Route, payload: []const u8) ?usize {
    if (payload.len > udp_payload_max) return null;
    @memcpy(out[headers..][0..payload.len], payload);
    return wrap(out, route, payload.len);
}

/// Emits a raw Ethernet/IPv4/TCP frame with no TCP options.
pub fn tcpFrame(
    out: *[frame.max_payload]u8,
    route: Route,
    seq: u32,
    acknowledgement: u32,
    flags: u8,
    window: u16,
    payload: []const u8,
) ?usize {
    if (payload.len > tcp_payload_max) return null;
    const segment_len = tcp_header + payload.len;
    ethernetIp(out, route, ip_header + segment_len, proto_tcp);
    const segment = out[eth_header + ip_header ..][0..segment_len];
    @memset(segment[0..tcp_header], 0);
    std.mem.writeInt(u16, segment[0..2], route.src_port, .big);
    std.mem.writeInt(u16, segment[2..4], route.dst_port, .big);
    std.mem.writeInt(u32, segment[4..8], seq, .big);
    std.mem.writeInt(u32, segment[8..12], acknowledgement, .big);
    segment[12] = 5 << 4;
    segment[13] = flags;
    std.mem.writeInt(u16, segment[14..16], window, .big);
    @memcpy(segment[tcp_header..], payload);
    std.mem.writeInt(u16, segment[16..18], transportChecksum(route.src_ip, route.dst_ip, proto_tcp, segment), .big);
    return eth_header + ip_header + segment_len;
}

fn ethernetIp(out: []u8, route: Route, ip_len: usize, protocol: u8) void {
    @memcpy(out[0..6], &route.dst_mac);
    @memcpy(out[6..12], &route.src_mac);
    std.mem.writeInt(u16, out[12..14], ethertype_ipv4, .big);
    const ip = out[eth_header..][0..ip_header];
    @memset(ip, 0);
    ip[0] = 0x45;
    std.mem.writeInt(u16, ip[2..4], @intCast(ip_len), .big);
    ip[8] = 64;
    ip[9] = protocol;
    @memcpy(ip[12..16], &route.src_ip);
    @memcpy(ip[16..20], &route.dst_ip);
    std.mem.writeInt(u16, ip[10..12], fold(sum(0, ip)), .big);
}

fn transportChecksum(src: [4]u8, dst: [4]u8, protocol: u8, bytes: []const u8) u16 {
    var acc = sum(0, &src);
    acc = sum(acc, &dst);
    acc += protocol + @as(u32, @intCast(bytes.len));
    return fold(sum(acc, bytes));
}

/// Adds `bytes` as big-endian 16-bit words to a one's-complement sum.
pub fn sum(start: u32, bytes: []const u8) u32 {
    var acc = start;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) acc += be16(bytes[i..][0..2]);
    if (bytes.len % 2 == 1) acc += @as(u32, bytes[bytes.len - 1]) << 8;
    return acc;
}

/// Folds a one's-complement sum to 16 bits and inverts it.
pub fn fold(start: u32) u16 {
    var acc = start;
    while (acc >> 16 != 0) acc = (acc & 0xFFFF) + (acc >> 16);
    return ~@as(u16, @truncate(acc));
}

fn be16(bytes: *const [2]u8) u16 {
    return std.mem.readInt(u16, bytes, .big);
}

fn be32(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, .big);
}
