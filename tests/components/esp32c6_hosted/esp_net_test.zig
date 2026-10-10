//! Real loopback proof for the C6 TCP and UDP host bridge.
const std = @import("std");
const ra8 = @import("ra8");
const hosted = ra8.components.esp_hosted;
const eth = hosted.eth;
const frame = hosted.frame;
const Bridge = hosted.net.Bridge;
const Queue = hosted.queue.Queue;

const guest_route = eth.Route{
    .src_mac = hosted.station.mac,
    .dst_mac = hosted.station.bssid,
    .src_ip = hosted.dhcp.lease_ip,
    .dst_ip = hosted.dhcp.server_ip,
    .src_port = 40000,
    .dst_port = 0,
};

fn sendTcp(bridge: *Bridge, queue: *Queue, port: u16, seq: u32, ack: u32, flags: u8, payload: []const u8) !void {
    var bytes: [frame.max_payload]u8 = undefined;
    var route = guest_route;
    route.dst_port = port;
    const len = eth.tcpFrame(&bytes, route, seq, ack, flags, 1460, payload).?;
    try std.testing.expectEqual(hosted.net.Result.handled, bridge.forward(queue, bytes[0..len]));
}

fn sendUdp(bridge: *Bridge, queue: *Queue, port: u16, payload: []const u8) !void {
    var bytes: [frame.max_payload]u8 = undefined;
    var route = guest_route;
    route.dst_port = port;
    const len = eth.udpFrame(&bytes, route, payload).?;
    try std.testing.expectEqual(hosted.net.Result.handled, bridge.forward(queue, bytes[0..len]));
}

fn popEthernet(queue: *Queue, out: *[frame.max_payload]u8) ?[]const u8 {
    var hosted_frame: [frame.frame_size]u8 = undefined;
    if (!queue.pop(&hosted_frame)) return null;
    const parsed = frame.parse(&hosted_frame) catch return null;
    @memcpy(out[0..parsed.payload.len], parsed.payload);
    return out[0..parsed.payload.len];
}

fn waitFrame(bridge: *Bridge, queue: *Queue, out: *[frame.max_payload]u8) ![]const u8 {
    for (0..2000) |_| {
        bridge.poll(queue);
        if (popEthernet(queue, out)) |bytes| return bytes;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.Timeout;
}

/// A loopback HTTP server that answers one request; cancelable while it waits.
const TcpHost = struct {
    server: *std.Io.net.Server,
    request: [64]u8 = undefined,
    request_len: usize = 0,

    fn serve(self: *TcpHost) !void {
        const io = std.testing.io;
        const stream = try self.server.accept(io);
        defer stream.close(io);
        const expected = "GET / HTTP/1.0\r\n\r\n";
        var in = stream.reader(io, &.{});
        try in.interface.readSliceAll(self.request[0..expected.len]);
        self.request_len = expected.len;
        var out = stream.writer(io, &.{});
        try out.interface.writeAll("HTTP/1.0 200 OK\r\nContent-Length: 8\r\n\r\nra8-loop");
    }
};

test "firmware TCP frames fetch an exact page from a real loopback server" {
    const io = std.testing.io;
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var host = TcpHost{ .server = &server };
    var serving = try io.concurrent(TcpHost.serve, .{&host});
    defer serving.cancel(io) catch {};

    var bridge: Bridge = .{ .net = .of(ra8.host.host_sock) };
    defer bridge.deinit();
    var queue: Queue = .{};
    const port = server.socket.address.getPort();
    try sendTcp(&bridge, &queue, port, 100, 0, eth.TcpFlag.syn, &.{});
    var bytes: [frame.max_payload]u8 = undefined;
    const syn_reply = try waitFrame(&bridge, &queue, &bytes);
    const syn_ack = eth.tcp(eth.ipv4(syn_reply).?).?;
    try std.testing.expectEqual(eth.TcpFlag.syn | eth.TcpFlag.ack, syn_ack.flags);
    try std.testing.expectEqual(@as(u32, 101), syn_ack.ack);
    const server_seq = syn_ack.seq +% 1;

    try sendTcp(&bridge, &queue, port, 101, server_seq, eth.TcpFlag.ack, &.{});
    const request = "GET / HTTP/1.0\r\n\r\n";
    try sendTcp(&bridge, &queue, port, 101, server_seq, eth.TcpFlag.psh | eth.TcpFlag.ack, request);
    _ = popEthernet(&queue, &bytes);

    const expected_response = "HTTP/1.0 200 OK\r\nContent-Length: 8\r\n\r\nra8-loop";
    var response: [expected_response.len]u8 = undefined;
    var response_len: usize = 0;
    var next_server = server_seq;
    while (response_len < response.len) {
        const incoming = try waitFrame(&bridge, &queue, &bytes);
        const segment = eth.tcp(eth.ipv4(incoming).?).?;
        if (segment.data.len == 0) continue;
        try std.testing.expectEqual(next_server, segment.seq);
        const take = @min(segment.data.len, response.len - response_len);
        @memcpy(response[response_len..][0..take], segment.data[0..take]);
        response_len += take;
        next_server +%= @intCast(segment.data.len);
        try sendTcp(&bridge, &queue, port, 101 + request.len, next_server, eth.TcpFlag.ack, &.{});
    }
    try serving.await(io);
    try std.testing.expectEqualSlices(u8, expected_response, &response);
    try std.testing.expectEqualSlices(u8, request, host.request[0..host.request_len]);

    try sendTcp(&bridge, &queue, port, 101 + request.len, next_server, eth.TcpFlag.fin | eth.TcpFlag.ack, &.{});
    _ = try waitFrame(&bridge, &queue, &bytes);
}

/// A loopback UDP socket that echoes one datagram; cancelable while it waits.
const UdpHost = struct {
    socket: *const std.Io.net.Socket,
    got: [32]u8 = undefined,
    got_len: usize = 0,

    fn echo(self: *UdpHost) !void {
        const io = std.testing.io;
        const message = try self.socket.receive(io, &self.got);
        self.got_len = message.data.len;
        try self.socket.send(io, &message.from, message.data);
    }
};

test "firmware UDP frames exchange a datagram with a real loopback socket" {
    const io = std.testing.io;
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    const socket = try address.bind(io, .{ .mode = .dgram });
    defer socket.close(io);
    var host = UdpHost{ .socket = &socket };
    var echoing = try io.concurrent(UdpHost.echo, .{&host});
    defer echoing.cancel(io) catch {};

    var bridge: Bridge = .{ .net = .of(ra8.host.host_sock) };
    defer bridge.deinit();
    var queue: Queue = .{};
    try sendUdp(&bridge, &queue, socket.address.getPort(), "ra8-udp");
    var bytes: [frame.max_payload]u8 = undefined;
    const incoming = try waitFrame(&bridge, &queue, &bytes);
    try echoing.await(io);
    try std.testing.expectEqualSlices(u8, "ra8-udp", eth.udp(incoming).?.data);
    try std.testing.expectEqualSlices(u8, "ra8-udp", host.got[0..host.got_len]);
}
