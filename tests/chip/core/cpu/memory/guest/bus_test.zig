//! Covers src/chip/core/cpu/memory/guest/bus.zig.
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.chip.core.memmap;
const registry = ra8.chip.periph.registry;
const Store = ra8.chip.core.cpu.memory.store.Store;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;
const GuestBus = ra8.chip.core.cpu.memory.guest.bus.GuestBus;
const BoardBus = ra8.chip.core.cpu.board_bus.BoardBus;

test "a store guest gives a bus over the store, with no engine open" {
    var store = try Store.init(null);
    defer store.deinit();
    const guest: Guest = .{ .store = &store };
    var memory = GuestBus.of(&guest, false);
    const view = memory.view();
    try view.writeWord(memmap.sram_base + 0x40, 0xCAFE_F00D);
    try std.testing.expectEqual(@as(u32, 0xCAFE_F00D), try guest.readWord(memmap.sram_base + 0x40));
    try std.testing.expect(!view.direct.?.enabled);
}

test "the board bus runs over a store: memory and the SCS go to it" {
    var store = try Store.init(null);
    defer store.deinit();
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    const guest: Guest = .{ .store = &store };
    var board: BoardBus = .{ .memory = GuestBus.of(&guest, false), .periph = &periph };
    const view = board.view();
    try view.writeWord(memmap.sram_base + 4, 0x0BAD_BEEF);
    try std.testing.expectEqual(@as(u32, 0x0BAD_BEEF), try guest.readWord(memmap.sram_base + 4));
    try std.testing.expectEqual(@as(u32, 0x0BAD_BEEF), try view.readWord(memmap.ns_sram_base + 4));
}
