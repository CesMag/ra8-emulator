//! The body of a `c6_bytes` or `c6_answer` boundary record: one Ethernet
//! frame a host socket (or a DNS lookup) put on the C6's queue for the
//! guest, and which call of the bridge put it there. Replay lands the same
//! frame at the same call with no socket.
//!
//! Layout, little-endian:
//!   u8  kind     0 socket bytes, 1 DNS answer
//!   u8  site     0 forwarding a guest frame, 1 polling the sockets
//!   u32 ordinal  which call of that site at the record's position
//!   u16 len      the frame's length
//!   frame
//!   u32 crc      CRC-32C over every byte above
const std = @import("std");
const hold = @import("ra8_components").esp_hosted.hold;
const record = @import("record.zig");
const Crc32c = std.hash.crc.@"CRC-32/ISCSI";

pub const Error = error{ Truncated, BadValue, BadCrc };

pub const Landing = struct {
    kind: hold.Kind,
    site: hold.Site,
    ordinal: u32,
    frame: []const u8,
};

const fixed_len: usize = 1 + 1 + 4 + 2;
const crc_len: usize = 4;

/// The boundary kind a landing of `kind` is recorded as.
pub fn whatOf(kind: hold.Kind) record.Boundary.What {
    return if (kind == .answer) .c6_answer else .c6_bytes;
}

pub fn encode(writer: *std.Io.Writer, landing: Landing) !void {
    var head: [fixed_len]u8 = undefined;
    head[0] = @backingInt(landing.kind);
    head[1] = @backingInt(landing.site);
    std.mem.writeInt(u32, head[2..6], landing.ordinal, .little);
    std.mem.writeInt(u16, head[6..8], std.math.cast(u16, landing.frame.len) orelse return error.BadValue, .little);
    var crc = Crc32c.init();
    crc.update(&head);
    crc.update(landing.frame);
    try writer.writeAll(&head);
    try writer.writeAll(landing.frame);
    try writer.writeInt(u32, crc.final(), .little);
}

/// Checks `body` and returns its landing, borrowing the frame from `body`.
pub fn decode(body: []const u8) Error!Landing {
    if (body.len < fixed_len + crc_len) return Error.Truncated;
    const len = std.mem.readInt(u16, body[6..8], .little);
    if (body.len != fixed_len + @as(usize, len) + crc_len) return Error.Truncated;
    if (Crc32c.hash(body[0 .. body.len - crc_len]) != std.mem.readInt(u32, body[body.len - crc_len ..][0..4], .little)) return Error.BadCrc;
    if (body[0] > 1 or body[1] > 1) return Error.BadValue;
    return .{
        .kind = @fromBackingInt(@intCast(body[0])),
        .site = @fromBackingInt(@intCast(body[1])),
        .ordinal = std.mem.readInt(u32, body[2..6], .little),
        .frame = body[fixed_len..][0..len],
    };
}
