//! The board's clock generation units in a snapshot (RA8EMU-670): PRCR,
//! the CKCR selects, the CKDIV dividers, the oscillators, sub-clock, LOCO,
//! the system clock tree, the PLLs, VSCR and its brown-out watch, LPM and
//! the deep-standby cancel bytes, GTCLKCR, OCTACLK and MSTP, as one
//! `clocks` section.
//!
//! Not saved, because it is wiring: each unit's pointers to its neighbours
//! (protection, oscillators, brown-out, voltage, selects, module stop,
//! attribution, bus, the OCTACLK watch), and MSTP's end-of-run report
//! (`last_gated` and the `dropped` log, which name peripherals by static
//! strings). A load keeps the target's.
const std = @import("std");
const file = @import("ra8_snapshot").file;
const fields = @import("ra8_snapshot").fields;

pub const Error = file.Error || fields.Error || error{Missing};

/// One board field and the wiring it carries.
const Part = struct { name: []const u8, skip: []const []const u8 = &.{} };

/// Format order. Appending is a format change.
const parts = [_]Part{
    .{ .name = "protection" },
    .{ .name = "branches", .skip = &.{"protection"} },
    .{ .name = "ratios", .skip = &.{ "protection", "branches" } },
    .{ .name = "oscillators", .skip = &.{"protection"} },
    .{ .name = "subclk", .skip = &.{"protection"} },
    .{ .name = "loco", .skip = &.{"protection"} },
    .{ .name = "tree", .skip = &.{ "protection", "oscillators", "brownout" } },
    .{ .name = "plls", .skip = &.{ "protection", "oscillators" } },
    .{ .name = "voltage", .skip = &.{"protection"} },
    .{ .name = "brownout", .skip = &.{"voltage"} },
    .{ .name = "low_power", .skip = &.{"protection"} },
    .{ .name = "standby_cancel" },
    .{ .name = "gpt_clock", .skip = &.{"modules"} },
    .{ .name = "octa", .skip = &.{"clocks"} },
    .{ .name = "modules", .skip = &.{ "attribution", "bus", "octa", "last_gated", "dropped" } },
};

pub fn save(board: anytype, writer: anytype) !void {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try body(&counter.writer, board);
    try file.writeSectionHeader(writer, .clocks, counter.fullCount());
    try body(writer, board);
}

fn body(writer: anytype, board: anytype) !void {
    inline for (parts) |part| try fields.writeExcept(writer, @field(board, part.name), part.skip);
}

/// All or nothing: every unit is read over a copy of itself, and the board
/// changes only once the whole section read cleanly.
pub fn load(board: anytype, bytes: []const u8) Error!void {
    const section = try file.Reader.find(bytes, .clocks) orelse return Error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    var copies: Copies(@TypeOf(board.*)) = undefined;
    inline for (parts, 0..) |part, i| {
        copies[i] = @field(board.*, part.name);
        try fields.readOver(&cursor, &copies[i], part.skip);
    }
    if (!cursor.done()) return Error.BadValue;
    inline for (parts, 0..) |part, i| @field(board.*, part.name) = copies[i];
}

/// The types of `parts`' fields of `Board`, as a tuple.
fn Copies(comptime Board: type) type {
    var types: [parts.len]type = undefined;
    for (parts, 0..) |part, i| types[i] = @FieldType(Board, part.name);
    return @Tuple(&types);
}
