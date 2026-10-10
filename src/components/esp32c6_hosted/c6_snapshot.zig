//! The board's ESP32-C6 companion in a snapshot (RA8EMU-687).
//!
//! Live host sockets are runtime resources: successful load closes and clears
//! them, while a failed load leaves the target bridge untouched.
const std = @import("std");
const file = @import("ra8_snapshot").file;
const fields = @import("ra8_snapshot").fields;

pub const Error = file.Error || fields.Error || error{Missing};

const wiring = .{ "pins", "wire.bridge" };

pub fn save(board: anytype, writer: anytype) !void {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try fields.writeExcept(&counter.writer, board.c6, wiring);
    try file.writeSectionHeader(writer, .c6, counter.fullCount());
    try fields.writeExcept(writer, board.c6, wiring);
}

/// All or nothing: failed parsing leaves emulated state and live sockets alone.
pub fn load(board: anytype, bytes: []const u8) Error!void {
    const section = try file.Reader.find(bytes, .c6) orelse return Error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    var copy: @TypeOf(board.c6) = .{ .pins = board.c6.pins };
    try fields.readOver(&cursor, &copy, wiring);
    if (!cursor.done() or !fits(copy.wire)) return Error.BadValue;
    board.c6.deinit();
    copy.wire.bridge = .{};
    board.c6 = copy;
}

fn fits(wire: anytype) bool {
    const queue = wire.queue;
    return wire.offset <= wire.rx.len and wire.caps_len <= wire.caps.len and
        queue.head < queue.slots.len and queue.len <= queue.slots.len;
}
