//! Covers src/session/mem_dump.zig's word(): memory first, then a peripheral
//! register read without side effects (RA8EMU-631).
const std = @import("std");
const ra8 = @import("ra8");

const mem_dump = ra8.session.mem_dump;
const registry = ra8.chip.periph.registry;
const Store = ra8.chip.core.cpu.memory.store.Store;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;

const sram: u32 = 0x2200_0000;

test "a word memory holds is read out of memory" {
    var store = try Store.init(null);
    defer store.deinit();
    const memory: Guest = .{ .store = &store };
    try memory.writeWord(sram, 0xCAFE_F00D);
    try std.testing.expectEqual(@as(?u32, 0xCAFE_F00D), mem_dump.word(memory, null, sram));
}

test "a register memory refuses is peeked off the bus" {
    var store = try Store.init(null);
    defer store.deinit();
    const memory: Guest = .{ .store = &store };
    var bus = registry.Bus.init(std.testing.allocator);
    defer bus.deinit();
    const at = registry.base + 0x40;
    try std.testing.expectEqual(@as(?u32, null), mem_dump.word(memory, &bus, at));
    bus.write(at, 4, 0x0000_00FF);
    try std.testing.expectEqual(@as(?u32, 0xFF), mem_dump.word(memory, &bus, at));
    try std.testing.expectEqual(@as(?u32, null), mem_dump.word(memory, null, at));
}
