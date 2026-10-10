//! RA8EMU-675: the self-contained data path units saved with non-default
//! state and loaded into fresh units compare equal, and a missing or short
//! section changes nothing.
const std = @import("std");
const ra8 = @import("ra8");
const Board = ra8.board.board.Board;
const file = ra8.snapshot.file;
const signals = ra8.chip.snapshot.signals;

fn Unit(comptime name: []const u8) type {
    return @FieldType(Board, name);
}

/// The Board's data path fields, under the Board's names.
const Stand = struct {
    links: Unit("links") = Unit("links").init(),
    pinfunc: Unit("pinfunc") = Unit("pinfunc").init(),
    checksum: Unit("checksum") = Unit("checksum").init(),
    dataops: Unit("dataops") = Unit("dataops").init(),
    accuracy: Unit("accuracy") = Unit("accuracy").init(),
    comparators: Unit("comparators") = Unit("comparators").init(),
    analog: Unit("analog") = Unit("analog").init(),
    adc: Unit("adc") = Unit("adc").init(),
    shutoff: Unit("shutoff") = Unit("shutoff").init(),
    dma_module: Unit("dma_module") = .{},
};

fn busy() Stand {
    var board: Stand = .{};
    board.links.elcr = 0x80;
    board.links.armed[2] = true;
    board.pinfunc.entries[3] = 0x0001_0004;
    board.pinfunc.programmed = 9;
    board.checksum.dor = 0xA5A5_0F0F;
    board.dataops.docr = 0x41;
    board.dataops.flag = true;
    board.accuracy.caulvr = 1200;
    board.comparators.channels[1].cmpctl = 0x81;
    board.analog.channels[0].dadr = 0x0800;
    board.adc.reg[1] = 0x1234;
    board.adc.last_code = 0x0FFF;
    board.shutoff.groups[1].asserts = 2;
    board.dma_module.dmast = 1;
    return board;
}

fn saved(board: *const Stand, list: *std.Io.Writer.Allocating) !void {
    try file.writeHeader(&list.writer);
    try signals.save(board, &list.writer);
}

test "every data path unit round-trips" {
    const board = busy();
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var target: Stand = .{};
    try signals.load(&target, list.written());
    try std.testing.expectEqualDeep(board, target);
}

test "a missing or short section changes nothing" {
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try file.writeHeader(&list.writer);
    var target: Stand = .{};
    try std.testing.expectError(error.Missing, signals.load(&target, list.written()));
    list.clearRetainingCapacity();
    const board = busy();
    try saved(&board, &list);
    const cut = list.written()[0 .. list.written().len - 3];
    try std.testing.expect(std.meta.isError(signals.load(&target, cut)));
    try std.testing.expectEqualDeep(Stand{}, target);
}
