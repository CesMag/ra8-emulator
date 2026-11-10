//! Adversarial and stress tests for RFC 6455 WebSocket / Raw TCP Transport Bridge.
const std = @import("std");
const ra8 = @import("ra8");
const ws_transport = ra8.rpc.ws_transport;
const ws_frame = ra8.rpc.ws_frame;
const ws_handshake = ra8.rpc.ws_handshake;
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

// ---------------------------------------------------------------------------
// 1. Raw TCP vs WebSocket auto-detection boundaries
// ---------------------------------------------------------------------------

test "stress: raw TCP binary hello [0x0A, 0x00, ...] delivered with zero delay and exact content" {
    var peers = try testPair();
    defer for (&peers) |*peer| peer.close();

    const server_t = peers[0].transport();
    const raw_hello = [_]u8{ 0x0A, 0x00, 0x00, 0x00, 0x01, 0x00, 0x52, 0x38, 0x41, 0x52 };

    try ready.sendAll(io, peers[1].stream.socket.handle, &raw_hello, 1000);
    try std.testing.expect((try ready.wait(io, peers[0].stream.socket.handle, 1000)).any());

    var rx_buf: [64]u8 = undefined;
    const got = try server_t.vtable.receive(server_t.ctx, &rx_buf);
    try std.testing.expectEqual(@as(usize, 10), got);
    try std.testing.expectEqualSlices(u8, &raw_hello, rx_buf[0..got]);
    try std.testing.expectEqual(ws_transport.State.raw, peers[0].state);
}

test "stress: raw TCP binary beginning with 'G' (not 'GET ') transitions to raw" {
    var peers = try testPair();
    defer for (&peers) |*peer| peer.close();

    const server_t = peers[0].transport();
    const binary_msg = [_]u8{ 'G', 0x00, 0x01, 0x02, 0xFF, 0xFE, 0xFD };

    try ready.sendAll(io, peers[1].stream.socket.handle, &binary_msg, 1000);
    try std.testing.expect((try ready.wait(io, peers[0].stream.socket.handle, 1000)).any());

    var rx_buf: [64]u8 = undefined;
    const got = try server_t.vtable.receive(server_t.ctx, &rx_buf);
    try std.testing.expectEqual(@as(usize, 7), got);
    try std.testing.expectEqualSlices(u8, &binary_msg, rx_buf[0..got]);
    try std.testing.expectEqual(ws_transport.State.raw, peers[0].state);
}

test "stress: raw TCP beginning with 'GET_' (not 'GET ') transitions to raw" {
    var peers = try testPair();
    defer for (&peers) |*peer| peer.close();

    const server_t = peers[0].transport();
    const cmd = "GET_STATUS\r\n";

    try ready.sendAll(io, peers[1].stream.socket.handle, cmd, 1000);
    try std.testing.expect((try ready.wait(io, peers[0].stream.socket.handle, 1000)).any());

    var rx_buf: [64]u8 = undefined;
    const got = try server_t.vtable.receive(server_t.ctx, &rx_buf);
    try std.testing.expectEqual(cmd.len, got);
    try std.testing.expectEqualStrings(cmd, rx_buf[0..got]);
    try std.testing.expectEqual(ws_transport.State.raw, peers[0].state);
}

// ---------------------------------------------------------------------------
// 2. Partial HTTP GET, pauses, and non-WebSocket HTTP requests
// ---------------------------------------------------------------------------

test "stress: partial HTTP 'G' then pause then 'ET ' then pause then headers" {
    var peers = try testPair();
    defer for (&peers) |*peer| peer.close();

    const server_t = peers[0].transport();

    // Send single byte 'G'
    try ready.sendAll(io, peers[1].stream.socket.handle, "G", 1000);
    try std.testing.expect((try ready.wait(io, peers[0].stream.socket.handle, 1000)).any());

    var rx_buf: [256]u8 = undefined;
    var got = try server_t.vtable.receive(server_t.ctx, &rx_buf);
    try std.testing.expectEqual(@as(usize, 0), got);
    try std.testing.expectEqual(ws_transport.State.detect, peers[0].state);

    // Send next 3 bytes "ET "
    try ready.sendAll(io, peers[1].stream.socket.handle, "ET ", 1000);
    try std.testing.expect((try ready.wait(io, peers[0].stream.socket.handle, 1000)).any());

    got = try server_t.vtable.receive(server_t.ctx, &rx_buf);
    try std.testing.expectEqual(@as(usize, 0), got);
    try std.testing.expectEqual(ws_transport.State.detect, peers[0].state);

    // Send rest of HTTP upgrade request
    const rest =
        "/ws HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Origin: http://localhost:4200\r\n" ++
        "Sec-WebSocket-Version: 13\r\n\r\n";
    try ready.sendAll(io, peers[1].stream.socket.handle, rest, 1000);
    try std.testing.expect((try ready.wait(io, peers[0].stream.socket.handle, 1000)).any());

    got = try server_t.vtable.receive(server_t.ctx, &rx_buf);
    try std.testing.expectEqual(@as(usize, 0), got);
    try std.testing.expectEqual(ws_transport.State.websocket, peers[0].state);

    // Verify client received 101 Switching Protocols
    try std.testing.expect((try ready.wait(io, peers[1].stream.socket.handle, 1000)).any());
    var client_rx: [256]u8 = undefined;
    var vec = [_][]u8{&client_rx};
    const client_got = try peers[1].stream.readWithControl(io, &vec, &.{});
    try std.testing.expect(std.mem.startsWith(u8, client_rx[0..client_got.data_len], "HTTP/1.1 101 Switching Protocols\r\n"));
}

test "stress: non-GET HTTP request (e.g. POST /) falls back to raw TCP" {
    var peers = try testPair();
    defer for (&peers) |*peer| peer.close();

    const server_t = peers[0].transport();
    const post_req = "POST /api/action HTTP/1.1\r\nHost: localhost\r\n\r\n";

    try ready.sendAll(io, peers[1].stream.socket.handle, post_req, 1000);
    try std.testing.expect((try ready.wait(io, peers[0].stream.socket.handle, 1000)).any());

    var rx_buf: [128]u8 = undefined;
    const got = try server_t.vtable.receive(server_t.ctx, &rx_buf);
    try std.testing.expectEqual(post_req.len, got);
    try std.testing.expectEqualStrings(post_req, rx_buf[0..got]);
    try std.testing.expectEqual(ws_transport.State.raw, peers[0].state);
}

test "stress: HTTP GET without WebSocket upgrade fails with BadMessage" {
    var peers = try testPair();
    defer for (&peers) |*peer| peer.close();

    const server_t = peers[0].transport();
    const plain_get = "GET /index.html HTTP/1.1\r\nHost: localhost\r\nUser-Agent: curl/8.0\r\n\r\n";

    try ready.sendAll(io, peers[1].stream.socket.handle, plain_get, 1000);
    try std.testing.expect((try ready.wait(io, peers[0].stream.socket.handle, 1000)).any());

    var rx_buf: [128]u8 = undefined;
    const err = server_t.vtable.receive(server_t.ctx, &rx_buf);
    try std.testing.expectError(error.BadMessage, err);
}

// ---------------------------------------------------------------------------
// 3. Forbidden Origin validation and rejection
// ---------------------------------------------------------------------------

test "stress: forbidden Origin http://evil.com fails handshake" {
    var peers = try testPair();
    defer for (&peers) |*peer| peer.close();

    const server_t = peers[0].transport();
    const evil_req =
        "GET /ws HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Origin: http://evil.com\r\n" ++
        "Sec-WebSocket-Version: 13\r\n\r\n";

    try ready.sendAll(io, peers[1].stream.socket.handle, evil_req, 1000);
    try std.testing.expect((try ready.wait(io, peers[0].stream.socket.handle, 1000)).any());

    var rx_buf: [128]u8 = undefined;
    const result = server_t.vtable.receive(server_t.ctx, &rx_buf);
    try std.testing.expectError(error.BadMessage, result);
}

test "stress: forbidden Origin prefix evasion http://localhost.evil.com rejected" {
    var peers = try testPair();
    defer for (&peers) |*peer| peer.close();

    const server_t = peers[0].transport();
    const evil_prefix =
        "GET /ws HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Origin: http://localhost.evil.com\r\n" ++
        "Sec-WebSocket-Version: 13\r\n\r\n";

    try ready.sendAll(io, peers[1].stream.socket.handle, evil_prefix, 1000);
    try std.testing.expect((try ready.wait(io, peers[0].stream.socket.handle, 1000)).any());

    var rx_buf: [128]u8 = undefined;
    const result = server_t.vtable.receive(server_t.ctx, &rx_buf);
    try std.testing.expectError(error.BadMessage, result);
}

// ---------------------------------------------------------------------------
// 4. Close handshake and socket teardown
// ---------------------------------------------------------------------------

test "stress: Close frame with status 1000 echoes close reply and closes transport" {
    var peers = try testPair();
    defer for (&peers) |*peer| peer.close();

    const server_t = peers[0].transport();
    peers[0].state = .websocket;

    const mask = [4]u8{ 0x11, 0x22, 0x33, 0x44 };
    var close_payload: [2]u8 = undefined;
    std.mem.writeInt(u16, &close_payload, ws_frame.CloseCode.normal_closure, .big);
    ws_frame.unmask(&close_payload, mask);

    var close_frame: [8]u8 = undefined;
    close_frame[0] = 0x88;
    close_frame[1] = 0x80 | 2;
    @memcpy(close_frame[2..6], &mask);
    @memcpy(close_frame[6..8], &close_payload);

    try ready.sendAll(io, peers[1].stream.socket.handle, &close_frame, 1000);
    try std.testing.expect((try ready.wait(io, peers[0].stream.socket.handle, 1000)).any());

    var rx_buf: [32]u8 = undefined;
    try std.testing.expectError(error.LinkDown, server_t.vtable.receive(server_t.ctx, &rx_buf));
    try std.testing.expectEqual(ws_transport.State.closed, peers[0].state);

    try std.testing.expect((try ready.wait(io, peers[1].stream.socket.handle, 1000)).any());
    var reply_buf: [16]u8 = undefined;
    var vec = [_][]u8{&reply_buf};
    const got = try peers[1].stream.readWithControl(io, &vec, &.{});
    try std.testing.expect(got.data_len >= 2);
    try std.testing.expectEqual(@as(u8, 0x88), reply_buf[0]);
}

test "stress: Close frame followed by subsequent receive/send returns LinkDown" {
    var peers = try testPair();
    defer for (&peers) |*peer| peer.close();

    const server_t = peers[0].transport();
    peers[0].state = .closed;

    var rx_buf: [32]u8 = undefined;
    try std.testing.expectError(error.LinkDown, server_t.vtable.receive(server_t.ctx, &rx_buf));
    try std.testing.expectError(error.LinkDown, server_t.vtable.send(server_t.ctx, "payload"));
    try std.testing.expectEqual(@as(usize, 0), server_t.vtable.poll(server_t.ctx));
}

test "stress: unmasked client frame in websocket mode is rejected with BadMessage" {
    var peers = try testPair();
    defer for (&peers) |*peer| peer.close();

    const server_t = peers[0].transport();
    peers[0].state = .websocket;

    const unmasked = [_]u8{ 0x82, 0x04, 't', 'e', 's', 't' };
    try ready.sendAll(io, peers[1].stream.socket.handle, &unmasked, 1000);
    try std.testing.expect((try ready.wait(io, peers[0].stream.socket.handle, 1000)).any());

    var rx_buf: [32]u8 = undefined;
    try std.testing.expectError(error.BadMessage, server_t.vtable.receive(server_t.ctx, &rx_buf));
}

// ---------------------------------------------------------------------------
// 5. Pipelining, fragmentation, and large frames
// ---------------------------------------------------------------------------

test "stress: pipelined frames in single TCP segment delivered sequentially" {
    var peers = try testPair();
    defer for (&peers) |*peer| peer.close();

    const server_t = peers[0].transport();
    peers[0].state = .websocket;

    const mask = [4]u8{ 0x12, 0x34, 0x56, 0x78 };

    // Frame 1: "first" (5 bytes)
    var p1: [5]u8 = undefined;
    @memcpy(&p1, "first");
    ws_frame.unmask(&p1, mask);
    var f1: [11]u8 = undefined;
    f1[0] = 0x82;
    f1[1] = 0x80 | 5;
    @memcpy(f1[2..6], &mask);
    @memcpy(f1[6..11], &p1);

    // Frame 2: "second_packet" (13 bytes)
    var p2: [13]u8 = undefined;
    @memcpy(&p2, "second_packet");
    ws_frame.unmask(&p2, mask);
    var f2: [19]u8 = undefined;
    f2[0] = 0x82;
    f2[1] = 0x80 | 13;
    @memcpy(f2[2..6], &mask);
    @memcpy(f2[6..19], &p2);

    // Concatenate both frames into one TCP transmission
    var pipelined: [30]u8 = undefined;
    @memcpy(pipelined[0..11], &f1);
    @memcpy(pipelined[11..30], &f2);

    try ready.sendAll(io, peers[1].stream.socket.handle, &pipelined, 1000);
    try std.testing.expect((try ready.wait(io, peers[0].stream.socket.handle, 1000)).any());

    // Receive first frame
    var rx1: [32]u8 = undefined;
    const got1 = try server_t.vtable.receive(server_t.ctx, &rx1);
    try std.testing.expectEqual(@as(usize, 5), got1);
    try std.testing.expectEqualStrings("first", rx1[0..got1]);

    // Receive second frame
    var rx2: [32]u8 = undefined;
    const got2 = try server_t.vtable.receive(server_t.ctx, &rx2);
    try std.testing.expectEqual(@as(usize, 13), got2);
    try std.testing.expectEqualStrings("second_packet", rx2[0..got2]);
}

test "stress: large WebSocket frame roundtrip (> 2048 bytes)" {
    var peers = try testPair();
    defer for (&peers) |*peer| peer.close();

    const server_t = peers[0].transport();
    peers[0].state = .websocket;

    // Server sends 4096-byte payload over WebSocket (tests large unmasked server binary encoding)
    const large_size: usize = 4096;
    var send_buf: [large_size]u8 = undefined;
    for (&send_buf, 0..) |*b, i| b.* = @as(u8, @truncate(i & 0xFF));

    try server_t.vtable.send(server_t.ctx, &send_buf);

    // Client receives: 4-byte 16-bit header (0x82, 126, 0x10, 0x00) + 4096 bytes payload
    var client_buf: [large_size + 16]u8 = undefined;
    var total_received: usize = 0;
    while (total_received < large_size + 4) {
        try std.testing.expect((try ready.wait(io, peers[1].stream.socket.handle, 2000)).any());
        var vec = [_][]u8{client_buf[total_received..]};
        const got = try peers[1].stream.readWithControl(io, &vec, &.{});
        if (got.data_len == 0) break;
        total_received += got.data_len;
    }

    try std.testing.expectEqual(large_size + 4, total_received);
    try std.testing.expectEqual(@as(u8, 0x82), client_buf[0]);
    try std.testing.expectEqual(@as(u8, 126), client_buf[1]);
    try std.testing.expectEqual(@as(u16, large_size), std.mem.readInt(u16, client_buf[2..4], .big));
    try std.testing.expectEqualSlices(u8, &send_buf, client_buf[4 .. 4 + large_size]);
}
