//! RA8EMU-683: the Ethernet switch saved with non-default state and loaded
//! into a fresh one compares equal; the target keeps its own wiring; a
//! missing or short section changes nothing.
const std = @import("std");
const ra8 = @import("ra8");
const Board = ra8.board.board.Board;
const file = ra8.snapshot.file;
const rswitch = ra8.board.snapshot.rswitch;

const Rswitch = @FieldType(Board, "rswitch");
const Machine = @FieldType(@FieldType(Rswitch, "gateway"), "mode");

var fwpc_a: [3]u32 = .{ 1, 2, 3 };
var fwpc_b: [3]u32 = .{ 4, 5, 6 };
var mode_b: Machine = .{};

/// The Board's switch field, under the Board's name.
const Stand = struct {
    rswitch: Rswitch = .{},
};

fn busy() Stand {
    var board: Stand = .{};
    board.rswitch.ports[0].mpsm = 0x11;
    board.rswitch.ports[1].dark_reads = 4;
    board.rswitch.forward.ports[1][0] = 5;
    board.rswitch.gateway.inits = 2;
    board.rswitch.gateway.mode.commands = 3;
    board.rswitch.gateway.fwpc = &fwpc_a;
    board.rswitch.pool.cabpirm = 7;
    board.rswitch.queues.config[1] = 0x33;
    board.rswitch.queues.rings.tx_frames = 9;
    return board;
}

fn saved(board: *const Stand, list: *std.Io.Writer.Allocating) !void {
    try file.writeHeader(&list.writer);
    try rswitch.save(board, &list.writer);
}

test "the Ethernet switch round-trips" {
    var board = busy();
    board.rswitch.gateway.fwpc = null;
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var target: Stand = .{};
    try rswitch.load(&target, list.written());
    try std.testing.expectEqualDeep(board, target);
}

test "a load keeps the target's wiring" {
    const board = busy();
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var target: Stand = .{};
    target.rswitch.gateway.fwpc = &fwpc_b;
    target.rswitch.queues.mode = &mode_b;
    try rswitch.load(&target, list.written());
    try std.testing.expectEqual(@as(u32, 9), target.rswitch.queues.rings.tx_frames);
    try std.testing.expectEqual(@as(u32, 3), target.rswitch.gateway.mode.commands);
    try std.testing.expect(target.rswitch.gateway.fwpc.? == &fwpc_b);
    try std.testing.expect(target.rswitch.queues.mode.? == &mode_b);
    try std.testing.expect(target.rswitch.ports[0].domain == null);
}

test "a missing or short section changes nothing" {
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try file.writeHeader(&list.writer);
    var target: Stand = .{};
    try std.testing.expectError(error.Missing, rswitch.load(&target, list.written()));
    list.clearRetainingCapacity();
    const board = busy();
    try saved(&board, &list);
    const cut = list.written()[0 .. list.written().len - 3];
    try std.testing.expect(std.meta.isError(rswitch.load(&target, cut)));
    try std.testing.expectEqualDeep(Stand{}, target);
}
