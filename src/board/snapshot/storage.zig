//! Option MRAM and the configured OSPI NOR contents in a snapshot
//! (RA8EMU-674), as one `storage` section.
//!
//! This file only keeps the order, which is the format: the option MRAM,
//! the xSPI controller, the NOR flash. The MRAM and the flash save their own
//! halves (chip/periph/mram/snapshot.zig,
//! components/nor_flash/snapshot.zig, RA8EMU-1104). The controller is
//! plain state apart from its wiring to the part and the OCTACLK watch.
const std = @import("std");
const file = @import("ra8_snapshot").file;
const fields = @import("ra8_snapshot").fields;
const options_half = @import("ra8_chip").periph.mram.snapshot;
const nor_half = @import("ra8_components").nor_flash.snapshot;

pub const Error = file.Error || fields.Error || error{ Missing, OutOfMemory };
const controller_wiring = .{ "part", "octa" };

pub fn save(board: anytype, writer: anytype) !void {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try body(&counter.writer, board);
    try file.writeSectionHeader(writer, .storage, counter.fullCount());
    try body(writer, board);
}

fn body(writer: anytype, board: anytype) !void {
    try options_half.write(writer, &board.options);
    try fields.writeExcept(writer, board.flash, controller_wiring);
    try nor_half.write(writer, &board.nor);
}

/// All-or-nothing: parse and validate both sparse lists before replacing
/// either target, including the selected flash capacity.
pub fn load(board: anytype, bytes: []const u8) Error!void {
    const section = try file.Reader.find(bytes, .storage) orelse return Error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    var options = try options_half.read(&cursor, &board.options);
    var controller = board.flash;
    try fields.readOver(&cursor, &controller, controller_wiring);
    const nor = try nor_half.read(&cursor);
    if (!cursor.done() or !options.fits() or !nor.fits(&board.nor)) return Error.BadValue;
    var cells = try options.build();
    errdefer cells.deinit();
    const flash = try nor.build(&board.nor);
    options.install(&board.options, cells);
    board.flash = controller;
    nor_half.install(&board.nor, flash);
}
