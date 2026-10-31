//! The board's two SD cards in a snapshot (RA8EMU-664): the SPI-mode card
//! on SCI0 and the SD host controller with its card, as one `sd` section.
//!
//! This file only keeps the order, which is the format: the SPI-mode card,
//! the host controller, the SD-bus card. Each model saves its own half
//! (components/sd_card/snapshot.zig, chip/periph/sdhi/snapshot.zig,
//! RA8EMU-1104). Not saved: the card's line on SCI0 (a pointer to the card,
//! wiring) and the volume `--sd-new` formatted (run report only).
const std = @import("std");
const file = @import("ra8_snapshot").file;
const fields = @import("ra8_snapshot").fields;
const blocks = @import("ra8_snapshot").blocks;
const cards = @import("ra8_components").sd_card.snapshot;
const host = @import("ra8_chip").periph.sdhi.snapshot;
const Spi = @import("ra8_components").sd_card.Card;
const Bus = @import("ra8_components").sd_card.bus_card.Card;
const Controller = @import("ra8_chip").periph.sdhi.Sdhi;

const Prepared = struct { spi: cards.Staged(Spi), controller: Controller, bus: cards.Staged(Bus) };

pub const Error = file.Error || fields.Error || error{ Missing, OutOfMemory };

pub fn save(board: anytype, writer: anytype) !void {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try body(&counter.writer, board);
    try file.writeSectionHeader(writer, .sd, counter.fullCount());
    try body(writer, board);
}

fn body(writer: anytype, board: anytype) !void {
    try cards.writeSpi(writer, &board.sd);
    try host.write(writer, &board.card);
    try cards.writeBus(writer, &board.host_card);
}

/// All or nothing: both cards and the controller change only once the whole
/// section read cleanly, every index is inside its buffer and both block
/// maps are built.
pub fn load(board: anytype, bytes: []const u8) Error!void {
    var staged = try prepare(board, bytes);
    var spi_map = try staged.spi.build();
    errdefer blocks.free(&spi_map);
    const bus_map = try staged.bus.build();
    staged.spi.install(&board.sd, spi_map);
    board.card = staged.controller;
    staged.bus.install(&board.host_card, bus_map);
}

/// Parse every card, controller field and block index without changing state
/// or allocating block maps. Startup admission uses the same parser as load.
pub fn validate(bytes: []const u8) Error!void {
    const blank = .{ .sd = Spi.init(std.heap.page_allocator), .card = Controller.init(), .host_card = Bus.init(std.heap.page_allocator) };
    _ = try prepare(&blank, bytes);
}

fn prepare(board: anytype, bytes: []const u8) Error!Prepared {
    const section = try file.Reader.find(bytes, .sd) orelse return Error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    const spi = try cards.readSpi(&cursor, &board.sd);
    const controller = try host.read(&cursor, &board.card);
    const bus = try cards.readBus(&cursor, &board.host_card);
    if (!cursor.done() or !cards.spiFits(&spi.card) or !host.fits(&controller)) return Error.BadValue;
    return .{ .spi = spi, .controller = controller, .bus = bus };
}
