//! The run's two SysTick time bases in a snapshot (RA8EMU-694): the secure
//! base and the Non-secure one at the SCS alias, secure first, as one
//! `systick` section. They live beside the board, not in it, so the board
//! section (RA8EMU-688) does not carry them.
//!
//! Not saved, because the run sets them when it is built: `per_chunk` and
//! `words`. A load keeps the target's own.
const std = @import("std");
const file = @import("ra8_snapshot").file;
const fields = @import("ra8_snapshot").fields;
const Clocks = @import("../periph/clocks.zig").Clocks;

pub const Error = file.Error || fields.Error || error{Missing};

const wiring = .{ "per_chunk", "words" };

pub fn save(bases: [2]*const Clocks, writer: anytype) !void {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try body(bases, &counter.writer);
    try file.writeSectionHeader(writer, .systick, counter.fullCount());
    try body(bases, writer);
}

fn body(bases: [2]*const Clocks, writer: anytype) !void {
    for (bases) |base| try fields.writeExcept(writer, base.*, wiring);
}

/// All or nothing: neither base changes until both read cleanly.
pub fn load(bases: [2]*Clocks, bytes: []const u8) Error!void {
    const section = try file.Reader.find(bytes, .systick) orelse return Error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    var copies = .{ bases[0].*, bases[1].* };
    try fields.readOver(&cursor, &copies[0], wiring);
    try fields.readOver(&cursor, &copies[1], wiring);
    if (!cursor.done()) return Error.BadValue;
    bases[0].* = copies[0];
    bases[1].* = copies[1];
}
