//! The body of a `usbip_traffic` boundary record: one thing the USB/IP host
//! did, as the bytes the bridge took off its socket. Replay feeds the same
//! bytes to the device with no socket.
//!
//! Layout, little-endian:
//!   u8  kind     1 import, 2 submit, 3 unlink, 4 disconnect
//!   u8  flags    bit 0: a disconnect that came after the poll's pump
//!   u16 head_len the command's header (the busid of an import)
//!   u32 data_len the OUT data a submit carries
//!   head, data
//!   u32 crc      CRC-32C over every byte above
//!
//! A reader that finds the CRC wrong or a length that does not fit the kind
//! refuses the record: replay feeding the device altered traffic would
//! diverge silently.
const std = @import("std");
const traffic = @import("ra8_board").usb.traffic;
const Crc32c = std.hash.crc.@"CRC-32/ISCSI";

pub const Error = error{ Truncated, BadValue, BadCrc };

pub const Event = traffic.Event;

pub const Flags = struct {
    pub const pumped: u8 = 1;
};

pub const fixed_len: usize = 1 + 1 + 2 + 4;
const crc_len: usize = 4;

/// The record for `event`, appended to `writer`.
pub fn encode(writer: *std.Io.Writer, event: Event) !void {
    try check(event);
    var head: [fixed_len]u8 = undefined;
    head[0] = @backingInt(event.kind);
    head[1] = if (event.pumped) Flags.pumped else 0;
    std.mem.writeInt(u16, head[2..4], @intCast(event.head.len), .little);
    std.mem.writeInt(u32, head[4..8], @intCast(event.data.len), .little);
    var crc = Crc32c.init();
    crc.update(&head);
    crc.update(event.head);
    crc.update(event.data);
    try writer.writeAll(&head);
    try writer.writeAll(event.head);
    try writer.writeAll(event.data);
    try writer.writeInt(u32, crc.final(), .little);
}

/// Checks `body` and returns its event, borrowing the bytes from `body`.
pub fn decode(body: []const u8) Error!Event {
    if (body.len < fixed_len + crc_len) return Error.Truncated;
    const head_len = std.mem.readInt(u16, body[2..4], .little);
    const data_len = std.mem.readInt(u32, body[4..8], .little);
    if (body.len != fixed_len + @as(usize, head_len) + data_len + crc_len) return Error.Truncated;
    const covered = body[0 .. body.len - crc_len];
    if (Crc32c.hash(covered) != std.mem.readInt(u32, body[body.len - crc_len ..][0..4], .little)) return Error.BadCrc;
    if (body[0] < @backingInt(traffic.Kind.import) or body[0] > @backingInt(traffic.Kind.disconnect)) return Error.BadValue;
    if (body[1] & ~Flags.pumped != 0) return Error.BadValue;
    const event: Event = .{
        .kind = @fromBackingInt(@intCast(body[0])),
        .pumped = body[1] & Flags.pumped != 0,
        .head = body[fixed_len..][0..head_len],
        .data = body[fixed_len + head_len ..][0..data_len],
    };
    check(event) catch return Error.BadValue;
    return event;
}

/// Whether `event` is shaped the way its kind is.
fn check(event: Event) error{BadValue}!void {
    if (event.pumped and event.kind != .disconnect) return error.BadValue;
    const ok = switch (event.kind) {
        .import => event.head.len >= 1 and event.head.len <= traffic.busid_max and event.data.len == 0,
        .submit => event.head.len == traffic.header_len and event.data.len <= traffic.max_data,
        .unlink => event.head.len == traffic.header_len and event.data.len == 0,
        .disconnect => event.head.len == 0 and event.data.len == 0,
    };
    if (!ok) return error.BadValue;
}
