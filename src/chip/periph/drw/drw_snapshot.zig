//! The board's DRW 2D engine in a snapshot (RA8EMU-667): registers,
//! texture source, edge limiters, both caches and counters, as one `raster`
//! section.
//!
//! Not saved, because it is wiring: `domain` (the power domain controller
//! the board points it at) and `memory` (the guest memory handle the board
//! attaches). A load keeps the target board's own.
const std = @import("std");
const file = @import("ra8_snapshot").file;
const fields = @import("ra8_snapshot").fields;

pub const Error = file.Error || fields.Error || error{Missing};

const wiring = .{ "domain", "memory" };

pub fn save(board: anytype, writer: anytype) !void {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try fields.writeExcept(&counter.writer, board.raster, wiring);
    try file.writeSectionHeader(writer, .raster, counter.fullCount());
    try fields.writeExcept(writer, board.raster, wiring);
}

/// All or nothing: the engine changes only once the whole section read
/// cleanly and the pixel cache's use count fits its cells.
pub fn load(board: anytype, bytes: []const u8) Error!void {
    const section = try file.Reader.find(bytes, .raster) orelse return Error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    var copy = board.raster;
    try fields.readOver(&cursor, &copy, wiring);
    const cache = copy.pixel_cache;
    if (!cursor.done() or cache.used > cache.cells.len) return Error.BadValue;
    board.raster = copy;
}
