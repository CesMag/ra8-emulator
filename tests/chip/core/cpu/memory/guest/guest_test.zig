//! Covers src/chip/core/cpu/memory/guest/guest.zig.
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.chip.core.memmap;
const Store = ra8.chip.core.cpu.memory.store.Store;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;
const Error = ra8.chip.core.cpu.memory.guest.Error;

test "a store guest reads back what it wrote, bytes and words" {
    var store = try Store.init(null);
    defer store.deinit();
    const guest = Guest{ .store = &store };
    try guest.writeWord(memmap.sram_base + 8, 0xCAFE_F00D);
    try std.testing.expectEqual(@as(u32, 0xCAFE_F00D), try guest.readWord(memmap.sram_base + 8));
    var byte: [1]u8 = undefined;
    try guest.read(memmap.sram_base + 8, &byte);
    try std.testing.expectEqual(@as(u8, 0x0D), byte[0]);
}

test "a store guest sees a Non-secure alias as the same bytes" {
    var store = try Store.init(null);
    defer store.deinit();
    const guest = Guest{ .store = &store };
    try guest.writeWord(memmap.sram_base, 0x1234_5678);
    const view = memmap.sram_base + memmap.ns_offset;
    try std.testing.expectEqual(@as(u32, 0x1234_5678), try guest.readWord(view));
}

test "a store guest refuses unmapped and region-straddling access" {
    var store = try Store.init(null);
    defer store.deinit();
    const guest = Guest{ .store = &store };
    try std.testing.expectError(Error.Unmapped, guest.readWord(0x9000_0000));
    try std.testing.expectError(Error.Unmapped, guest.writeWord(0x9000_0000, 1));
    const last = memmap.dtcm_end - 2;
    try std.testing.expectError(Error.Unmapped, guest.readWord(last));
}

test "a store guest maps a window once and reads and writes through it" {
    var store = try Store.init(null);
    defer store.deinit();
    const guest = Guest{ .store = &store };
    try std.testing.expectError(Error.Unmapped, guest.readWord(0x02E0_7600));
    try guest.map(0x02E0_7000, 0x1000);
    try guest.writeWord(0x02E0_7600, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), try guest.readWord(0x02E0_7600));
    try std.testing.expectError(error.Mapped, guest.map(0x02E0_7000, 0x1000));
}
