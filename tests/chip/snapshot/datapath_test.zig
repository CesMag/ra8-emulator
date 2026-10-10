//! RA8EMU-676: the data path units that carry wiring, saved with non-default
//! state and loaded into fresh units, compare equal; the target keeps its
//! own wiring; a missing or short section changes nothing.
const std = @import("std");
const ra8 = @import("ra8");
const Board = ra8.board.board.Board;
const file = ra8.snapshot.file;
const datapath = ra8.chip.snapshot.datapath;

fn Unit(comptime name: []const u8) type {
    return @FieldType(Board, name);
}

var guard_a = Unit("protection").init();
var guard_b = Unit("protection").init();
var bank_a: Unit("dma_module") = .{};
var bank_b: Unit("dma_module") = .{};

/// The Board's wired data path fields, under the Board's names.
const Stand = struct {
    events: Unit("events"),
    transfers: Unit("transfers"),
    transfers1: Unit("transfers1"),
    dma: Unit("dma"),
    pins: Unit("pins"),
    backup: Unit("backup"),
    battery_switch: Unit("battery_switch"),

    fn wiredTo(guard: anytype, bank: anytype) Stand {
        return .{
            .events = Unit("events").init(),
            .transfers = Unit("transfers").init(),
            .transfers1 = Unit("transfers1").init(),
            .dma = Unit("dma").init(bank),
            .pins = Unit("pins").init(),
            .backup = Unit("backup").init(guard),
            .battery_switch = Unit("battery_switch").init(guard),
        };
    }
};

fn busy() Stand {
    var board = Stand.wiredTo(&guard_a, &bank_a);
    board.events.links[2] = 0x41;
    board.events.raised = 7;
    board.transfers.dtcvbr = 0x2200_0000;
    board.transfers1.activations = 3;
    board.dma.channels[1].dmsar = 0x2000_1000;
    board.dma.refused = 1;
    board.pins.led_edges[1] = 4;
    board.pins.refused = 2;
    board.backup.data[3] = 0x5A;
    board.backup.writes = 6;
    board.battery_switch.value = 1;
    return board;
}

fn saved(board: *const Stand, list: *std.Io.Writer.Allocating) !void {
    try file.writeHeader(&list.writer);
    try datapath.save(board, &list.writer);
}

test "every wired data path unit round-trips" {
    const board = busy();
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var target = Stand.wiredTo(&guard_a, &bank_a);
    try datapath.load(&target, list.written());
    try std.testing.expectEqualDeep(board, target);
}

test "a load keeps the target's wiring" {
    var board = busy();
    board.transfers.twin = &board.transfers1;
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var target = Stand.wiredTo(&guard_b, &bank_b);
    try datapath.load(&target, list.written());
    try std.testing.expect(target.dma.bank == &bank_b);
    try std.testing.expect(target.backup.protection == &guard_b);
    try std.testing.expect(target.battery_switch.protection == &guard_b);
    try std.testing.expect(target.transfers.twin == null);
    try std.testing.expectEqual(@as(u8, 0x5A), target.backup.data[3]);
}

test "a missing or short section changes nothing" {
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try file.writeHeader(&list.writer);
    const fresh = Stand.wiredTo(&guard_a, &bank_a);
    var target = fresh;
    try std.testing.expectError(error.Missing, datapath.load(&target, list.written()));
    list.clearRetainingCapacity();
    const board = busy();
    try saved(&board, &list);
    const cut = list.written()[0 .. list.written().len - 3];
    try std.testing.expect(std.meta.isError(datapath.load(&target, cut)));
    try std.testing.expectEqualDeep(fresh, target);
}
