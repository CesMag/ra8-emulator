//! The board's SCI unit in a snapshot (RA8EMU-663): every channel and the
//! line buffer, as one `serial` section.
//!
//! A channel's attached device and the line's sink point into the board,
//! so they are wiring: not written, and a load keeps the ones the board
//! already has. Host stdin and touch inputs are run options, not state.
const std = @import("std");
const sci = @import("sci.zig");
const file = @import("ra8_snapshot").file;
const fields = @import("ra8_snapshot").fields;

pub const Error = file.Error || fields.Error || error{Missing};

const channel_wiring = .{"device"};
const line_wiring = .{ "sink", "mute" };

pub fn save(board: anytype, writer: anytype) !void {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try body(&counter.writer, &board.serial);
    try file.writeSectionHeader(writer, .serial, counter.fullCount());
    try body(writer, &board.serial);
}

fn body(writer: anytype, unit: *const sci.Sci) !void {
    for (unit.channels) |channel| try fields.writeExcept(writer, channel, channel_wiring);
    try fields.writeExcept(writer, unit.line, line_wiring);
}

/// All or nothing: the unit changes only once the whole section read
/// cleanly and every ring and line index lands inside its buffer.
pub fn load(board: anytype, bytes: []const u8) Error!void {
    const section = try file.Reader.find(bytes, .serial) orelse return Error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    var copy = board.serial;
    for (&copy.channels) |*channel| try fields.readOver(&cursor, channel, channel_wiring);
    try fields.readOver(&cursor, &copy.line, line_wiring);
    if (!cursor.done() or !fits(&copy)) return Error.BadValue;
    board.serial = copy;
}

fn fits(unit: *const sci.Sci) bool {
    for (unit.channels) |channel| {
        const ring = channel.rx;
        if (ring.head >= ring.bytes.len or ring.tail >= ring.bytes.len) return false;
    }
    const line = unit.line;
    return line.last_len <= line.last.len and line.pending_len <= line.pending.len;
}
