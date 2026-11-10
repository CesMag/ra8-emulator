//! RFC 6455 WebSocket Handshake & Origin validation tests (RA8EMU-1241).
const std = @import("std");
const ra8 = @import("ra8");
const ws_handshake = ra8.rpc.ws_handshake;

test "ws_handshake auto-detection detects HTTP GET vs raw TCP RPC" {
    try std.testing.expect(ws_handshake.isHttpUpgrade("GET / HTTP/1.1\r\n"));
    try std.testing.expect(ws_handshake.isHttpUpgrade("GET /ws HTTP/1.1\r\n"));
    // Raw TCP RPC hello starts with 0x0A 0x00 0x00 0x00 0x01 0x00 'R' 'A' '8' 'R'
    const raw_hello = [_]u8{ 0x0A, 0x00, 0x00, 0x00, 0x01, 0x00, 0x52, 0x38, 0x41, 0x52 };
    try std.testing.expect(!ws_handshake.isHttpUpgrade(&raw_hello));
    try std.testing.expect(!ws_handshake.isHttpUpgrade("POST / HTTP/1.1\r\n"));
    try std.testing.expect(!ws_handshake.isHttpUpgrade(""));
}

test "ws_handshake parses valid RFC 6455 upgrade request" {
    const req_text =
        "GET /ws HTTP/1.1\r\n" ++
        "Host: localhost:8080\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Origin: http://localhost:4200\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n";

    const req = try ws_handshake.parseRequest(req_text);
    try std.testing.expectEqualStrings("/ws", req.path);
    try std.testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", req.key);
    try std.testing.expectEqualStrings("http://localhost:4200", req.origin.?);
    try std.testing.expect(req.is_websocket);
    try std.testing.expect(req.connection_upgrade);
    try std.testing.expect(req.version_13);
}

test "ws_handshake computes canonical RFC 6455 Sec-WebSocket-Accept" {
    var accept: [ws_handshake.accept_len]u8 = undefined;
    ws_handshake.computeAccept("dGhlIHNhbXBsZSBub25jZQ==", &accept);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &accept);
}

test "ws_handshake formats HTTP 101 Switching Protocols response" {
    var accept: [ws_handshake.accept_len]u8 = undefined;
    ws_handshake.computeAccept("dGhlIHNhbXBsZSBub25jZQ==", &accept);

    var resp_buf: [ws_handshake.response_buf_size]u8 = undefined;
    const resp = try ws_handshake.formatResponse(&accept, &resp_buf);

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 101 Switching Protocols\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, resp, "Upgrade: websocket\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Connection: Upgrade\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, resp, "\r\n\r\n"));
}

test "ws_handshake validates permitted and rejected origins" {
    try std.testing.expect(ws_handshake.isOriginAllowed(null));
    try std.testing.expect(ws_handshake.isOriginAllowed("http://localhost:4200"));
    try std.testing.expect(ws_handshake.isOriginAllowed("http://localhost"));
    try std.testing.expect(ws_handshake.isOriginAllowed("http://127.0.0.1:4200"));
    try std.testing.expect(ws_handshake.isOriginAllowed("http://127.0.0.1"));
    try std.testing.expect(ws_handshake.isOriginAllowed("https://localhost:8443"));
    try std.testing.expect(!ws_handshake.isOriginAllowed("http://evil.com"));
    try std.testing.expect(!ws_handshake.isOriginAllowed("http://localhost.evil.com"));
    try std.testing.expect(!ws_handshake.isOriginAllowed("https://evil.org:4200"));
}

test "ws_handshake handles case-insensitive headers and multi-token connection" {
    const req_text =
        "GET / HTTP/1.1\r\n" ++
        "host: localhost:8080\r\n" ++
        "upgrade: WebSocket\r\n" ++
        "connection: keep-alive, Upgrade\r\n" ++
        "sec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "\r\n";

    const req = try ws_handshake.parseRequest(req_text);
    try std.testing.expect(req.is_websocket);
    try std.testing.expect(req.connection_upgrade);
}

test "ws_handshake error rejection for malformed and invalid requests" {
    // Incomplete request
    try std.testing.expectError(error.IncompleteRequest, ws_handshake.parseRequest("GET / HTTP/1.1\r\nUpgrade: websocket\r\n"));

    // Not GET method
    try std.testing.expectError(error.InvalidMethod, ws_handshake.parseRequest("POST / HTTP/1.1\r\n\r\n"));

    // Missing key
    const no_key =
        "GET / HTTP/1.1\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n\r\n";
    try std.testing.expectError(error.MissingKey, ws_handshake.parseRequest(no_key));

    // Unsupported version
    const bad_ver =
        "GET / HTTP/1.1\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 8\r\n\r\n";
    try std.testing.expectError(error.UnsupportedVersion, ws_handshake.parseRequest(bad_ver));

    // Forbidden origin
    const bad_origin =
        "GET / HTTP/1.1\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Origin: http://evil.attacker.com\r\n\r\n";
    try std.testing.expectError(error.ForbiddenOrigin, ws_handshake.parseRequest(bad_origin));
}
