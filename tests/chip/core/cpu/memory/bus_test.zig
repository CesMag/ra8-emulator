//! Covers src/chip/core/cpu/memory/bus.zig.
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.chip.core.memmap;
const bus = ra8.chip.core.cpu.bus;
const Store = ra8.chip.core.cpu.memory.store.Store;
const MemoryBus = ra8.chip.core.cpu.memory.memory_bus.MemoryBus;

test "the Zig core reads and writes its own memory with no engine open" {
    var store = try Store.init(null);
    defer store.deinit();
    var memory: MemoryBus = .{ .store = &store };
    const view = memory.view();
    try view.write(memmap.sram_base + 8, &.{ 0x0D, 0xF0, 0xAD, 0x0B });
    try std.testing.expectEqual(@as(u32, 0x0BAD_F00D), try view.readWord(memmap.sram_base + 8));
    try std.testing.expectEqual(@as(u32, 0x0BAD_F00D), try view.readWord(memmap.ns_sram_base + 8));
    try std.testing.expect(!view.direct.?.enabled);
}

test "the direct path, when on, is the store's own MRAM and SRAM pages" {
    var store = try Store.init(null);
    defer store.deinit();
    var memory: MemoryBus = .{ .store = &store, .fast_enabled = true };
    const view = memory.view();
    try std.testing.expect(view.direct.?.enabled);
    try view.write(memmap.mram_base + 0x20, &.{ 0x12, 0x34, 0x56, 0x78 });
    try std.testing.expectEqual(@as(u8, 0x12), store.span(memmap.mram_base + 0x20, 1).?[0]);
    try view.write(memmap.ns_sram_base, &.{0x99});
    try std.testing.expectEqual(@as(u8, 0x99), store.span(memmap.sram_base, 1).?[0]);
}

test "an access off the memory map, or across a region's end, is unmapped" {
    var store = try Store.init(null);
    defer store.deinit();
    var memory: MemoryBus = .{ .store = &store };
    const view = memory.view();
    try std.testing.expectError(bus.Error.Unmapped, view.readWord(0x4000_0000));
    try std.testing.expectError(bus.Error.Unmapped, view.readWord(memmap.dtcm_end - 2));
    try std.testing.expectError(bus.Error.Unmapped, view.write(0x4000_0000, &.{0}));
}
