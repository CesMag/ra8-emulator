//! The esp-hosted frame: a 12-byte packed header followed by its payload.
//!
//! Every SPI transaction between the RA8 and the ESP32-C6 clocks one
//! 1600-byte frame each way. The header is esp-hosted-mcu's
//! `struct esp_payload_header`: byte 0 packs if_type (bits 3:0) and if_num
//! (bits 7:4), the 16-bit fields are little endian, and the checksum is a
//! wrapping 16-bit byte sum from the header through the payload with the
//! checksum field counted as zero. An idle filler is if_type = max_if,
//! if_num = 0xF and nothing else.
const std = @import("std");

pub const frame_size: u16 = 1600;
pub const header_size: u16 = 12;
pub const max_payload: u16 = frame_size - header_size;
pub const filler_if_num: u4 = 0xF;

/// esp-hosted-mcu's `ESP_*_IF` interface numbers, as the bench
/// co-processor build numbers them (slot zero unused, max_if = 8).
pub const Interface = enum(u4) {
    invalid = 0,
    sta = 1,
    ap = 2,
    serial = 3,
    hci = 4,
    priv = 5,
    test_if = 6,
    eth = 7,
    max_if = 8,
    _,
};

pub const Header = struct {
    interface: Interface = .max_if,
    if_num: u4 = 0,
    flags: u8 = 0,
    len: u16 = 0,
    offset: u16 = 0,
    checksum: u16 = 0,
    seq: u16 = 0,
    throttle: u2 = 0,
    pkt_type: u8 = 0,

    pub fn decode(bytes: *const [header_size]u8) Header {
        return .{
            .interface = @fromBackingInt(@intCast(@as(u4, @truncate(bytes[0])))),
            .if_num = @truncate(bytes[0] >> 4),
            .flags = bytes[1],
            .len = std.mem.readInt(u16, bytes[2..4], .little),
            .offset = std.mem.readInt(u16, bytes[4..6], .little),
            .checksum = std.mem.readInt(u16, bytes[6..8], .little),
            .seq = std.mem.readInt(u16, bytes[8..10], .little),
            .throttle = @truncate(bytes[10]),
            .pkt_type = bytes[11],
        };
    }

    pub fn encode(self: Header, out: *[header_size]u8) void {
        out[0] = @as(u8, @backingInt(self.interface)) | @as(u8, self.if_num) << 4;
        out[1] = self.flags;
        std.mem.writeInt(u16, out[2..4], self.len, .little);
        std.mem.writeInt(u16, out[4..6], self.offset, .little);
        std.mem.writeInt(u16, out[6..8], self.checksum, .little);
        std.mem.writeInt(u16, out[8..10], self.seq, .little);
        out[10] = self.throttle;
        out[11] = self.pkt_type;
    }

    pub fn isFiller(self: Header) bool {
        return self.interface == .max_if and self.if_num == filler_if_num and
            self.len == 0;
    }
};

/// Upstream `compute_checksum()` over `frame[0 .. offset + len]`, skipping
/// the two checksum bytes as if they were zero.
pub fn checksum(frame: []const u8) u16 {
    var sum: u16 = 0;
    for (frame, 0..) |byte, index| {
        if (index == 6 or index == 7) continue;
        sum +%= byte;
    }
    return sum;
}

pub const Error = error{ ShortFrame, BadOffset, BadLength, BadChecksum };

/// Check a received frame and return its header and payload.
pub fn parse(frame: []const u8) Error!struct { header: Header, payload: []const u8 } {
    if (frame.len < header_size) return Error.ShortFrame;
    const header = Header.decode(frame[0..header_size]);
    if (header.isFiller()) return .{ .header = header, .payload = frame[0..0] };
    if (header.offset < header_size) return Error.BadOffset;
    const end = @as(usize, header.offset) + header.len;
    if (end > frame.len or end > frame_size) return Error.BadLength;
    if (checksum(frame[0..end]) != header.checksum) return Error.BadChecksum;
    return .{ .header = header, .payload = frame[header.offset..end] };
}

/// Fill `out` with one frame carrying `payload`; the rest is zero.
pub fn build(out: *[frame_size]u8, header: Header, payload: []const u8) Error!void {
    if (payload.len > max_payload) return Error.BadLength;
    @memset(out, 0);
    var h = header;
    h.len = @intCast(payload.len);
    h.offset = header_size;
    h.checksum = 0;
    @memcpy(out[header_size..][0..payload.len], payload);
    h.encode(out[0..header_size]);
    h.checksum = checksum(out[0 .. header_size + payload.len]);
    h.encode(out[0..header_size]);
}

/// Fill `out` with the co-processor's idle filler frame.
pub fn filler(out: *[frame_size]u8) void {
    @memset(out, 0);
    const h: Header = .{ .interface = .max_if, .if_num = filler_if_num };
    h.encode(out[0..header_size]);
}
