//! Covers src/board/wiring.zig: every part's board fits the peripheral
//! registry. An RA8P1 board once tipped over the block limit and every
//! `--device ra8p1` run stopped at TooManyBlocks (RA8EMU-94), so this attaches
//! a whole board per part and checks the bus still has room.
const std = @import("std");
const ra8 = @import("ra8");

const Part = ra8.chip.core.part.Part;
const max_blocks = ra8.chip.periph.registry.max_blocks;
const Store = ra8.chip.core.cpu.memory.store.Store;

/// The blocks a board of this part puts on the bus, over the Zig core's
/// store with no engine open: how a `--cpu zig` run attaches them.
fn attachedBlocks(which: Part) !usize {
    var store = try Store.init(null);
    defer store.deinit();
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    board.part = which;
    try ra8.board.wiring.attachBlocks(&board, .{ .store = &store });
    return board.bus.count;
}

test "an RA8P1 board attaches under the registry limit" {
    const count = try attachedBlocks(.ra8p1);
    try std.testing.expect(count > 0);
    try std.testing.expect(count < max_blocks);
}

test "an RA8D2 board attaches under the registry limit" {
    const count = try attachedBlocks(.ra8d2);
    try std.testing.expect(count > 0);
    try std.testing.expect(count < max_blocks);
}

test "CPU0's PPB windows are seeded into a store with no engine open" {
    var store = try Store.init(null);
    defer store.deinit();
    const memory: ra8.chip.core.cpu.memory.guest.Guest = .{ .store = &store };
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try ra8.board.wiring.primeWindows(&board, memory, .{
        .partitions = &board.partitions,
        .regions = &board.regions,
        .regions_ns = &board.regions_ns,
        .guard = &board.guard,
        .identity = ra8.chip.periph.cpuid.cpu0,
        .control = &board.control,
        .clears = &board.clears,
    });
    const memmap = ra8.chip.core.memmap;
    try std.testing.expectEqual(ra8.chip.periph.cpuid.cpu0, try memory.readWord(ra8.chip.periph.cpuid.address));
    try std.testing.expectEqual(ra8.chip.periph.mpu.geometry.type_value, try memory.readWord(memmap.mpu.type_));
    try std.testing.expectEqual(ra8.chip.periph.sau.geometry.type_value, try memory.readWord(memmap.sau.type_));
}
