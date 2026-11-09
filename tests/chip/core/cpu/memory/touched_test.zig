const std = @import("std");
const memory = @import("ra8").chip.core.cpu.memory;
const memmap = @import("ra8").chip.core.memmap;

test "written page accounting includes zero bytes, boundaries and aliases but ignores reads" {
    var store = try memory.store.Store.init(null);
    defer store.deinit();
    const zero = [_]u8{ 0, 0 };
    try store.write(.cpu0, memmap.sram_base + 4095, &zero);
    try std.testing.expectEqual(@as(usize, 2), store.touches().sram.count());
    try store.write(.cpu1, memmap.ns_sram_base + 4095, &zero);
    try std.testing.expectEqual(@as(usize, 2), store.touches().sram.count());
    var bytes: [2]u8 = undefined;
    try store.read(.none, memmap.sram_base + 8192, &bytes);
    try std.testing.expectEqual(@as(usize, 2), store.touches().sram.count());
    store.wipe();
    try std.testing.expectEqual(@as(usize, 0), store.touches().sram.count());
}

test "snapshot and undo restoration mark page provenance unavailable until wipe" {
    var store = try memory.store.Store.init(null);
    defer store.deinit();
    try store.write(.cpu0, memmap.sram_base, &.{0});
    try std.testing.expect(store.touches().valid);
    store.barrier(.snapshot_load);
    try std.testing.expect(!store.touches().valid);
    store.wipe();
    try std.testing.expect(store.touches().valid);
    try store.rawWrite(memmap.sram_base, &.{0});
    try std.testing.expect(!store.touches().valid);
}
