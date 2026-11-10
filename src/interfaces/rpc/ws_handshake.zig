//! RFC 6455 WebSocket Handshake and HTTP Upgrade parser for RA8EMU-1241.
const std = @import("std");

/// RFC 6455 magic GUID for Sec-WebSocket-Accept computation (§1.3).
pub const rfc6455_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Maximum length of Sec-WebSocket-Key allowed (standard Base64 key is 24 bytes).
pub const max_key_len: usize = 64;

/// Length of computed Sec-WebSocket-Accept string (28 bytes).
pub const accept_len: usize = std.base64.standard.Encoder.calcSize(std.crypto.hash.Sha1.digest_length);

/// Buffer size to format a 101 Switching Protocols response.
pub const response_buf_size: usize = 256;

/// Handshake errors during detection and header parsing.
pub const Error = error{
    IncompleteRequest,
    IncompleteHeaders,
    InvalidMethod,
    NotGetMethod,
    MissingKey,
    InvalidKey,
    InvalidUpgrade,
    NotWebSocket,
    InvalidConnection,
    UnsupportedVersion,
    ForbiddenOrigin,
    BufferTooSmall,
};

/// Result of parsing an HTTP upgrade request.
pub const Request = struct {
    path: []const u8,
    key: []const u8,
    origin: ?[]const u8,
    is_websocket: bool,
    connection_upgrade: bool,
    version_13: bool,
};

/// Checks if incoming bytes begin with an HTTP GET request (auto-detection).
pub fn isHttpUpgrade(bytes: []const u8) bool {
    if (bytes.len < 4) return false;
    return std.mem.startsWith(u8, bytes, "GET ");
}

/// Checks if an Origin header is permitted.
/// Accepts null/empty (non-browser clients), localhost, and 127.0.0.1 on any port.
pub fn isOriginAllowed(origin: ?[]const u8) bool {
    const org = origin orelse return true;
    if (org.len == 0 or std.mem.eql(u8, org, "null")) return true;

    const allowed_prefixes = [_][]const u8{
        "http://localhost",
        "https://localhost",
        "http://127.0.0.1",
        "https://127.0.0.1",
    };
    for (allowed_prefixes) |prefix| {
        if (std.mem.startsWith(u8, org, prefix)) {
            if (org.len == prefix.len) return true;
            const next_byte = org[prefix.len];
            if (next_byte == ':' or next_byte == '/') return true;
        }
    }
    return false;
}

pub const isAllowedOrigin = isOriginAllowed;

/// Checks if a comma/space-separated header value contains `token` (case-insensitive).
pub fn containsTokenIgnoreCase(header_val: []const u8, token: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, header_val, ", \t\r\n");
    while (it.next()) |part| {
        if (std.ascii.eqlIgnoreCase(part, token)) return true;
    }
    return false;
}

/// Finds the end of HTTP headers (`\r\n\r\n` or `\n\n`) and returns the byte offset.
pub fn findHeaderEnd(bytes: []const u8) ?usize {
    if (std.mem.indexOf(u8, bytes, "\r\n\r\n")) |pos| return pos + 4;
    if (std.mem.indexOf(u8, bytes, "\n\n")) |pos| return pos + 2;
    return null;
}

/// Parses an HTTP WebSocket upgrade request from `bytes`.
pub fn parseRequest(bytes: []const u8) Error!Request {
    const header_end = findHeaderEnd(bytes) orelse return error.IncompleteRequest;
    const header_text = bytes[0..header_end];

    var lines = std.mem.splitScalar(u8, header_text, '\n');
    const req_line = lines.next() orelse return error.IncompleteRequest;
    const trimmed_req = std.mem.trim(u8, req_line, " \r\t");

    var parts = std.mem.tokenizeScalar(u8, trimmed_req, ' ');
    const method = parts.next() orelse return error.InvalidMethod;
    if (!std.mem.eql(u8, method, "GET")) return error.InvalidMethod;

    const path = parts.next() orelse "/";

    var key: ?[]const u8 = null;
    var origin: ?[]const u8 = null;
    var is_ws = false;
    var conn_upgrade = false;
    var ver_13 = false;
    var has_version = false;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const name = trimmed[0..colon];
        const val = std.mem.trim(u8, trimmed[colon + 1 ..], " \r\t");

        if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
            if (containsTokenIgnoreCase(val, "websocket")) is_ws = true;
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            if (containsTokenIgnoreCase(val, "upgrade")) conn_upgrade = true;
        } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-key")) {
            key = val;
        } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-version")) {
            has_version = true;
            if (std.mem.eql(u8, val, "13")) ver_13 = true;
        } else if (std.ascii.eqlIgnoreCase(name, "origin")) {
            origin = val;
        }
    }

    if (!is_ws) return error.InvalidUpgrade;
    if (!conn_upgrade) return error.InvalidConnection;
    const found_key = key orelse return error.MissingKey;
    if (found_key.len == 0 or found_key.len > max_key_len) return error.InvalidKey;
    if (has_version and !ver_13) return error.UnsupportedVersion;
    if (!isOriginAllowed(origin)) return error.ForbiddenOrigin;

    return Request{
        .path = path,
        .key = found_key,
        .origin = origin,
        .is_websocket = is_ws,
        .connection_upgrade = conn_upgrade,
        .version_13 = if (has_version) ver_13 else true,
    };
}

pub const parse = parseRequest;

/// Computes the Sec-WebSocket-Accept response header value from client `key`.
pub fn computeAccept(key: []const u8, out: *[accept_len]u8) void {
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(key);
    hasher.update(rfc6455_guid);
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    hasher.final(&digest);
    _ = std.base64.standard.Encoder.encode(out, &digest);
}

/// Formats the HTTP 101 Switching Protocols response into `out`.
pub fn formatResponse(accept_key: *const [accept_len]u8, out: []u8) Error![]const u8 {
    const template_pre =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: ";
    const template_post = "\r\n\r\n";
    const total_len = template_pre.len + accept_len + template_post.len;

    if (out.len < total_len) return error.BufferTooSmall;

    @memcpy(out[0..template_pre.len], template_pre);
    @memcpy(out[template_pre.len..][0..accept_len], accept_key);
    @memcpy(out[template_pre.len + accept_len ..][0..template_post.len], template_post);

    return out[0..total_len];
}

/// Formats an HTTP error response (e.g. 403 Forbidden or 400 Bad Request).
pub fn formatErrorResponse(status_code: u16, status_text: []const u8, out: []u8) ![]const u8 {
    return std.fmt.bufPrint(out, "HTTP/1.1 {d} {s}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n", .{ status_code, status_text });
}
