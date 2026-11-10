//! RFC 6455 WebSocket Framing for RA8EMU-1241.
const std = @import("std");

/// RFC 6455 frame opcodes (§5.2).
pub const Opcode = enum(u4) {
    continuation = 0x00,
    text = 0x01,
    binary = 0x02,
    close = 0x08,
    ping = 0x09,
    pong = 0x0A,
    _,

    pub fn isControl(self: Opcode) bool {
        return @backingInt(self) >= 0x08;
    }
};

/// Maximum server header size in bytes: 1 (fin/opcode) + 1 (len byte) + 8 (ext len) = 10.
pub const max_server_header_bytes: usize = 10;

/// Maximum client header size in bytes: 10 + 4 (mask key) = 14.
pub const max_client_header_bytes: usize = 14;

/// Standard WebSocket Close Status Codes (RFC 6455 §7.4.1).
pub const CloseCode = struct {
    pub const normal_closure: u16 = 1000;
    pub const going_away: u16 = 1001;
    pub const protocol_error: u16 = 1002;
    pub const unsupported_data: u16 = 1003;
    pub const policy_violation: u16 = 1008;
    pub const message_too_big: u16 = 1009;
    pub const internal_error: u16 = 1011;
};

/// Frame parsing error set.
pub const Error = error{
    ReservedBitSet,
    ReservedBitsSet,
    UnsupportedOpcode,
    InvalidOpcode,
    ControlFrameTooLarge,
    ControlFrameFragmented,
    FragmentedControlFrame,
    UnmaskedClientFrame,
    PayloadTooLarge,
    NonMinimalEncoding,
    BufferTooSmall,
};

/// Decoded WebSocket frame header.
pub const Header = struct {
    fin: bool,
    rsv: u3,
    opcode: Opcode,
    masked: bool,
    payload_len: usize,
    mask: [4]u8,
    mask_key: [4]u8,
    header_len: usize,
    frame_len: usize,
};

/// Parses a frame header from `bytes`. Returns null if incomplete.
pub fn parseHeader(bytes: []const u8) Error!?Header {
    if (bytes.len < 2) return null;

    const b0 = bytes[0];
    const fin = (b0 & 0x80) != 0;
    const rsv: u3 = @truncate((b0 >> 4) & 0x07);
    if (rsv != 0) return error.ReservedBitsSet;

    const opcode_val = b0 & 0x0F;
    const opcode: Opcode = switch (opcode_val) {
        0x00 => .continuation,
        0x01 => .text,
        0x02 => .binary,
        0x08 => .close,
        0x09 => .ping,
        0x0A => .pong,
        else => return error.InvalidOpcode,
    };

    if (opcode.isControl() and !fin) return error.FragmentedControlFrame;

    const b1 = bytes[1];
    const masked = (b1 & 0x80) != 0;
    const len_code = b1 & 0x7F;

    var header_len: usize = 2;
    if (len_code == 126) {
        header_len += 2;
    } else if (len_code == 127) {
        header_len += 8;
    }
    if (masked) header_len += 4;

    if (bytes.len < header_len) return null;

    var payload_len: usize = 0;
    var ext_offset: usize = 2;
    if (len_code < 126) {
        payload_len = len_code;
    } else if (len_code == 126) {
        const ext = std.mem.readInt(u16, bytes[ext_offset..][0..2], .big);
        if (ext < 126) return error.NonMinimalEncoding;
        payload_len = ext;
        ext_offset += 2;
    } else {
        const ext = std.mem.readInt(u64, bytes[ext_offset..][0..8], .big);
        if (ext <= 0xFFFF) return error.NonMinimalEncoding;
        if ((ext & (@as(u64, 1) << 63)) != 0) return error.PayloadTooLarge;
        if (ext > std.math.maxInt(usize)) return error.PayloadTooLarge;
        payload_len = @intCast(ext);
        ext_offset += 8;
    }

    if (opcode.isControl() and payload_len > 125) return error.ControlFrameTooLarge;

    var mask_key = [_]u8{ 0, 0, 0, 0 };
    if (masked) {
        @memcpy(&mask_key, bytes[ext_offset..][0..4]);
    }

    const frame_len = header_len + payload_len;

    return Header{
        .fin = fin,
        .rsv = rsv,
        .opcode = opcode,
        .masked = masked,
        .payload_len = payload_len,
        .mask = mask_key,
        .mask_key = mask_key,
        .header_len = header_len,
        .frame_len = frame_len,
    };
}

/// Parses a client frame header and enforces that client frames are masked.
pub fn parseClientHeader(bytes: []const u8) Error!?Header {
    const hdr = (try parseHeader(bytes)) orelse return null;
    if (!hdr.masked) return error.UnmaskedClientFrame;
    return hdr;
}

/// Unmasks a WebSocket payload in-place using the 4-byte client mask.
pub fn unmask(payload: []u8, mask: [4]u8) void {
    unmaskOffset(payload, mask, 0);
}

/// Unmasks a WebSocket payload in-place with a stream mask offset.
pub fn unmaskOffset(payload: []u8, mask: [4]u8, offset: usize) void {
    for (payload, 0..) |*b, i| {
        b.* ^= mask[(offset + i) % 4];
    }
}

/// Writes an unmasked server frame header into `out` and returns the header slice.
pub fn encodeServerHeader(out: []u8, opcode: Opcode, payload_len: usize) []const u8 {
    const b0: u8 = 0x80 | @as(u8, @backingInt(opcode));
    out[0] = b0;

    if (payload_len < 126) {
        out[1] = @as(u8, @intCast(payload_len));
        return out[0..2];
    } else if (payload_len <= 0xFFFF) {
        out[1] = 126;
        std.mem.writeInt(u16, out[2..4], @as(u16, @intCast(payload_len)), .big);
        return out[0..4];
    } else {
        out[1] = 127;
        std.mem.writeInt(u64, out[2..10], @as(u64, @intCast(payload_len)), .big);
        return out[0..10];
    }
}

/// Formats a complete unmasked binary server frame (opcode 0x02) into `out`.
pub fn encodeServerBinary(payload: []const u8, out: []u8) Error!usize {
    if (out.len < 2 + payload.len) return error.BufferTooSmall;
    var hdr_buf: [10]u8 = undefined;
    const hdr = encodeServerHeader(&hdr_buf, .binary, payload.len);
    if (out.len < hdr.len + payload.len) return error.BufferTooSmall;
    @memcpy(out[0..hdr.len], hdr);
    @memcpy(out[hdr.len..][0..payload.len], payload);
    return hdr.len + payload.len;
}

/// Formats an unmasked Pong response frame (opcode 0x0A) into `out`.
pub fn encodePong(payload: []const u8, out: []u8) Error!usize {
    if (payload.len > 125) return error.ControlFrameTooLarge;
    if (out.len < 2 + payload.len) return error.BufferTooSmall;
    out[0] = 0x8A;
    out[1] = @as(u8, @intCast(payload.len));
    @memcpy(out[2..][0..payload.len], payload);
    return 2 + payload.len;
}

/// Formats an unmasked Close frame (opcode 0x08) with optional reason into `out`.
pub fn encodeClose(code: u16, reason: []const u8, out: []u8) Error!usize {
    const payload_len = 2 + reason.len;
    if (payload_len > 125) return error.ControlFrameTooLarge;
    if (out.len < 2 + payload_len) return error.BufferTooSmall;
    out[0] = 0x88;
    out[1] = @as(u8, @intCast(payload_len));
    std.mem.writeInt(u16, out[2..4], code, .big);
    if (reason.len > 0) {
        @memcpy(out[4..][0..reason.len], reason);
    }
    return 2 + payload_len;
}
