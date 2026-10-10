//! The board's GLCDC display controller in a snapshot (RA8EMU-668):
//! register file, both CLUT palettes, scanner, blend layers, mixer, output
//! stage, timing controller and system counters, as one `display` section.
//!
//! Not saved, because it is wiring: `domain` (the power domain controller
//! pointer), `memory` (the guest memory handle), `event_hook`, and on the
//! output stage the host frame `capture` buffer and the `vsync` hook a
//! frames-out run installs. A load keeps the target board's own. The mixer's
//! stage and palette pointers are per-call arguments, never stored, so
//! nothing needs re-pointing.
const std = @import("std");
const file = @import("ra8_snapshot").file;
const fields = @import("ra8_snapshot").fields;
const clut = @import("clut.zig");

pub const Error = file.Error || fields.Error || error{Missing};

const wiring = .{ "domain", "memory", "output", "event_hook" };
const host = .{ "capture", "vsync" };

pub fn save(board: anytype, writer: anytype) !void {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try body(&counter.writer, board.display);
    try file.writeSectionHeader(writer, .display, counter.fullCount());
    try body(writer, board.display);
}

fn body(writer: anytype, display: anytype) !void {
    try fields.writeExcept(writer, display, wiring);
    try fields.writeExcept(writer, display.output, host);
}

/// All or nothing: the controller changes only once the whole section read
/// cleanly and every palette's selected plane and filled counts fit.
pub fn load(board: anytype, bytes: []const u8) Error!void {
    const section = try file.Reader.find(bytes, .display) orelse return Error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    var copy = board.display;
    try fields.readOver(&cursor, &copy, wiring);
    try fields.readOver(&cursor, &copy.output, host);
    if (!cursor.done() or !fits(copy.palettes)) return Error.BadValue;
    board.display = copy;
}

fn fits(palettes: anytype) bool {
    for (palettes) |palette| {
        if (palette.selected >= clut.geometry.planes) return false;
        for (palette.filled) |filled| if (filled > clut.geometry.entries) return false;
    }
    return true;
}
