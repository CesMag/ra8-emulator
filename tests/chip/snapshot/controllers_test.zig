//! RA8EMU-672: the fixed-size memory controllers saved with non-default
//! state and loaded into fresh units compare equal, and a missing or short
//! section changes nothing.
const std = @import("std");
const ra8 = @import("ra8");
const Board = ra8.board.board.Board;
const file = ra8.snapshot.file;
const controllers = ra8.chip.snapshot.controllers;

fn Unit(comptime name: []const u8) type {
    return @FieldType(Board, name);
}

/// The Board's memory controller fields, under the Board's names.
const Stand = struct {
    memory_rates: Unit("memory_rates") = .{},
    memory_ecc: Unit("memory_ecc") = .{},
    sdram: Unit("sdram") = .{},
    cipher: Unit("cipher") = Unit("cipher").init(),
    ecc: Unit("ecc") = Unit("ecc").init(),
};

fn busy() Stand {
    var board: Stand = .{};
    board.memory_rates.code.mhz = 250;
    board.memory_rates.code.latched = 2;
    board.memory_rates.pfb = 1;
    board.memory_rates.hot_changes = 3;
    board.memory_ecc.decoder.value = 0x8C01;
    board.memory_ecc.code_status = 0x10;
    board.memory_ecc.speed = 4;
    board.sdram.words[2] = 0xDEAD_BEEF;
    board.sdram.sdckocr = 1;
    board.sdram.writes = 5;
    board.cipher.channels[0].convareast = 0x9000_0000;
    board.cipher.channels[0].shadow[3] = 0x5A;
    board.cipher.channels[1].enables = 6;
    board.ecc.esr = 0x0101;
    board.ecc.walk[0] = .wrote;
    board.ecc.shadow[1] = 0x1234_5678;
    board.ecc.lock.open_secure = true;
    board.ecc.lock.accepted = 7;
    return board;
}

fn saved(board: *const Stand, list: *std.Io.Writer.Allocating) !void {
    try file.writeHeader(&list.writer);
    try controllers.save(board, &list.writer);
}

test "every memory controller round-trips" {
    const board = busy();
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var target: Stand = .{};
    try controllers.load(&target, list.written());
    try std.testing.expectEqualDeep(board, target);
}

test "a missing or short section changes nothing" {
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try file.writeHeader(&list.writer);
    var target: Stand = .{};
    try std.testing.expectError(error.Missing, controllers.load(&target, list.written()));
    list.clearRetainingCapacity();
    const board = busy();
    try saved(&board, &list);
    const cut = list.written()[0 .. list.written().len - 3];
    try std.testing.expect(std.meta.isError(controllers.load(&target, cut)));
    try std.testing.expectEqualDeep(Stand{}, target);
}
