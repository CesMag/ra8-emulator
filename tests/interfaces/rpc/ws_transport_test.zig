//! WebSocket / Raw TCP auto-detecting transport tests (RA8EMU-1241).
const std = @import("std");
const ra8 = @import("ra8");
const ws_transport = ra8.rpc.ws_transport;
const ws_frame = ra8.rpc.ws_frame;
const Connection = ws_transport.Connection;
const ready = ra8.host.sock.ready;
const io = std.testing.io;

fn testPair() ![2]Connection {
    var listener = try (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{});
    defer listener.deinit(io);
    const client = try Connection.tcp(io, listener.socket.address);
    errdefer client.stream.close(io);
    try std.testing.expect((try ready.wait(io, listener.socket.handle, 1000)).any());
    return .{ .{ .stream = try listener.accept(io), .io = io }, client };
}

test "ws_transport auto-detects raw TCP client and passes greeting with zero loss" {
    var peers = try testPair();
    defer for (&peers) |*peer| peer.close();

    const server_t = peers[0].transport();
    const client_t = peers[1].transport();

    // Client sends raw RPC hello
    const raw_hello = [_]u8{ 0x0A, 0x00, 0x00, 0x00, 0x01, 0x00, 0x52, 0x38, 0x41, 0x52 };
    try client_t.vtable.send(client_t.ctx, &raw_hello);

    try std.testing.expect((try ready.wait(io, peers[0].stream.socket.handle, 1000)).any());

    var rx_buf: [32]u8 = undefined;
    const got = try server_t.vtable.receive(server_t.ctx, &rx_buf);
    try std.testing.expectEqual(@as(usize, 10), got);
    try std.testing.expectEqualSlices(u8, &raw_hello, rx_buf[0..got]);
    try std.testing.expectEqual(ws_transport.State.raw, peers[0].state);

    // Server sends raw reply
    try server_t.vtable.send(server_t.ctx, "raw_reply");
    try std.testing.expect((try ready.wait(io, peers[1].stream.socket.handle, 1000)).any());

    var client_rx: [32]u8 = undefined;
    const client_got = try client_t.vtable.receive(client_t.ctx, &client_rx);
    try std.testing.expectEqual(@as(usize, 9), client_got);
    try std.testing.expectEqualStrings("raw_reply", client_rx[0..client_got]);
}

test "ws_transport handles HTTP GET WebSocket upgrade and transitions to websocket" {
    var peers = try testPair();
    defer for (&peers) |*peer| peer.close();

    const server_t = peers[0].transport();

    // Raw HTTP GET request from client
    const upgrade_req =
        "GET /ws HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Origin: http://localhost:4200\r\n" ++
        "Sec-WebSocket-Version: 13\r\n\r\n";

    try ready.sendAll(io, peers[1].stream.socket.handle, upgrade_req, 1000);

    try std.testing.expect((try ready.wait(io, peers[0].stream.socket.handle, 1000)).any());

    // Server receives: triggers auto-detection, performs handshake, returns 0 payload
    var server_rx: [64]u8 = undefined;
    const initial_got = try server_t.vtable.receive(server_t.ctx, &server_rx);
    try std.testing.expectEqual(@as(usize, 0), initial_got);
    try std.testing.expectEqual(ws_transport.State.websocket, peers[0].state);

    // Client verifies HTTP 101 response
    try std.testing.expect((try ready.wait(io, peers[1].stream.socket.handle, 1000)).any());
    var resp_buf: [256]u8 = undefined;
    var vec = [_][]u8{&resp_buf};
    const resp_got = try peers[1].stream.readWithControl(io, &vec, &.{});
    const resp_str = resp_buf[0..resp_got.data_len];
    try std.testing.expect(std.mem.startsWith(u8, resp_str, "HTTP/1.1 101 Switching Protocols\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, resp_str, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != null);

    // Now client sends masked binary frame: payload "hello_ws"
    const mask = [4]u8{ 0x12, 0x34, 0x56, 0x78 };
    var masked_payload: [8]u8 = undefined;
    @memcpy(&masked_payload, "hello_ws");
    ws_frame.unmask(&masked_payload, mask);

    var client_frame: [14]u8 = undefined;
    client_frame[0] = 0x82; // FIN + binary
    client_frame[1] = 0x80 | 8; // MASK + len 8
    @memcpy(client_frame[2..6], &mask);
    @memcpy(client_frame[6..14], &masked_payload);

    try ready.sendAll(io, peers[1].stream.socket.handle, &client_frame, 1000);
    try std.testing.expect((try ready.wait(io, peers[0].stream.socket.handle, 1000)).any());

    const ws_got = try server_t.vtable.receive(server_t.ctx, &server_rx);
    try std.testing.expectEqual(@as(usize, 8), ws_got);
    try std.testing.expectEqualStrings("hello_ws", server_rx[0..ws_got]);

    // Server sends binary frame back
    try server_t.vtable.send(server_t.ctx, "ws_reply");

    var raw_reply_buf: [64]u8 = undefined;
    var reply_len: usize = 0;
    while (reply_len < 10) {
        try std.testing.expect((try ready.wait(io, peers[1].stream.socket.handle, 1000)).any());
        var reply_vec = [_][]u8{raw_reply_buf[reply_len..]};
        const chunk = try peers[1].stream.readWithControl(io, &reply_vec, &.{});
        if (chunk.data_len == 0) break;
        reply_len += chunk.data_len;
    }
    const raw_reply = raw_reply_buf[0..reply_len];
    try std.testing.expectEqual(@as(u8, 0x82), raw_reply[0]); // Unmasked server binary
    try std.testing.expectEqual(@as(u8, 8), raw_reply[1]);
    try std.testing.expectEqualStrings("ws_reply", raw_reply[2..10]);
}

test "ws_transport answers Ping with Pong immediately without interrupting receive" {
    var peers = try testPair();
    defer for (&peers) |*peer| peer.close();

    const server_t = peers[0].transport();
    peers[0].state = .websocket;

    // Client sends masked Ping frame (opcode 0x09) with payload "ping_test"
    const mask = [4]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    var masked_ping: [9]u8 = undefined;
    @memcpy(&masked_ping, "ping_test");
    ws_frame.unmask(&masked_ping, mask);

    var ping_frame: [15]u8 = undefined;
    ping_frame[0] = 0x89; // FIN + ping
    ping_frame[1] = 0x80 | 9; // MASK + len 9
    @memcpy(ping_frame[2..6], &mask);
    @memcpy(ping_frame[6..15], &masked_ping);

    // Also send binary frame immediately after ping
    var masked_bin: [4]u8 = undefined;
    @memcpy(&masked_bin, "data");
    ws_frame.unmask(&masked_bin, mask);
    var bin_frame: [10]u8 = undefined;
    bin_frame[0] = 0x82; // FIN + binary
    bin_frame[1] = 0x80 | 4;
    @memcpy(bin_frame[2..6], &mask);
    @memcpy(bin_frame[6..10], &masked_bin);

    var combined: [25]u8 = undefined;
    @memcpy(combined[0..15], &ping_frame);
    @memcpy(combined[15..25], &bin_frame);
    try ready.sendAll(io, peers[1].stream.socket.handle, &combined, 1000);

    var rx_buf: [32]u8 = undefined;
    var got: usize = 0;
    while (got == 0) {
        try std.testing.expect((try ready.wait(io, peers[0].stream.socket.handle, 1000)).any());
        got = try server_t.vtable.receive(server_t.ctx, &rx_buf);
    }
    try std.testing.expectEqual(@as(usize, 4), got);
    try std.testing.expectEqualStrings("data", rx_buf[0..got]);

    // Client checks Pong frame was received
    try std.testing.expect((try ready.wait(io, peers[1].stream.socket.handle, 1000)).any());
    var pong_buf: [32]u8 = undefined;
    var vec = [_][]u8{&pong_buf};
    const pong_got = try peers[1].stream.readWithControl(io, &vec, &.{});
    const pong_data = pong_buf[0..pong_got.data_len];
    try std.testing.expectEqual(@as(u8, 0x8A), pong_data[0]); // Unmasked Pong
    try std.testing.expectEqual(@as(u8, 9), pong_data[1]);
    try std.testing.expectEqualStrings("ping_test", pong_data[2..11]);
}

test "ws_transport handles Close frame and returns error.LinkDown" {
    var peers = try testPair();
    defer for (&peers) |*peer| peer.close();

    const server_t = peers[0].transport();
    peers[0].state = .websocket;

    // Client sends masked Close frame (opcode 0x08)
    const mask = [4]u8{ 1, 2, 3, 4 };
    var close_frame: [6]u8 = undefined;
    close_frame[0] = 0x88; // FIN + close
    close_frame[1] = 0x80 | 0; // MASK + len 0
    @memcpy(close_frame[2..6], &mask);

    try ready.sendAll(io, peers[1].stream.socket.handle, &close_frame, 1000);
    try std.testing.expect((try ready.wait(io, peers[0].stream.socket.handle, 1000)).any());

    var rx_buf: [32]u8 = undefined;
    try std.testing.expectError(error.LinkDown, server_t.vtable.receive(server_t.ctx, &rx_buf));
    try std.testing.expectEqual(ws_transport.State.closed, peers[0].state);

    // Client receives Close response from server
    try std.testing.expect((try ready.wait(io, peers[1].stream.socket.handle, 1000)).any());
    var close_reply: [16]u8 = undefined;
    var vec = [_][]u8{&close_reply};
    const got = try peers[1].stream.readWithControl(io, &vec, &.{});
    try std.testing.expect(got.data_len >= 2);
    try std.testing.expectEqual(@as(u8, 0x88), close_reply[0]);
}

test "ws_transport poll reports buffered bytes and socket readiness" {
    var peers = try testPair();
    defer for (&peers) |*peer| peer.close();

    const server_t = peers[0].transport();
    try std.testing.expectEqual(@as(usize, 0), server_t.vtable.poll(server_t.ctx));

    peers[0].rx_len = 10;
    try std.testing.expect(server_t.vtable.poll(server_t.ctx) > 0);
}

test "ws_transport reassembles fragmented binary + continuation frames and rejects stray continuation" {
    var peers = try testPair();
    defer for (&peers) |*peer| peer.close();

    const server_t = peers[0].transport();
    peers[0].state = .websocket;

    const mask1 = [4]u8{ 0x11, 0x22, 0x33, 0x44 };
    var part1: [5]u8 = undefined;
    @memcpy(&part1, "hello");
    ws_frame.unmask(&part1, mask1);

    var frame1: [11]u8 = undefined;
    frame1[0] = 0x02; // FIN=0 + binary
    frame1[1] = 0x80 | 5;
    @memcpy(frame1[2..6], &mask1);
    @memcpy(frame1[6..11], &part1);

    const mask2 = [4]u8{ 0x55, 0x66, 0x77, 0x88 };
    var part2: [6]u8 = undefined;
    @memcpy(&part2, "_world");
    ws_frame.unmask(&part2, mask2);

    var frame2: [12]u8 = undefined;
    frame2[0] = 0x80; // FIN=1 + continuation (0x00)
    frame2[1] = 0x80 | 6;
    @memcpy(frame2[2..6], &mask2);
    @memcpy(frame2[6..12], &part2);

    var combined: [23]u8 = undefined;
    @memcpy(combined[0..11], &frame1);
    @memcpy(combined[11..23], &frame2);
    try ready.sendAll(io, peers[1].stream.socket.handle, &combined, 1000);

    var out: [32]u8 = undefined;
    var total: usize = 0;
    while (total < 11) {
        try std.testing.expect((try ready.wait(io, peers[0].stream.socket.handle, 1000)).any() or peers[0].rx_len > 0);
        total += try server_t.vtable.receive(server_t.ctx, out[total..]);
    }
    try std.testing.expectEqualStrings("hello_world", out[0..total]);

    // Stray continuation frame when not in fragmented state returns error.BadMessage
    try ready.sendAll(io, peers[1].stream.socket.handle, &frame2, 1000);
    try std.testing.expect((try ready.wait(io, peers[0].stream.socket.handle, 1000)).any());
    try std.testing.expectError(error.BadMessage, server_t.vtable.receive(server_t.ctx, &out));
}
