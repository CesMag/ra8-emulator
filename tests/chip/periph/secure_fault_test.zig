//! Tests for src/chip/periph/secure_fault.zig, against a fake core.

const std = @import("std");
const ra8 = @import("ra8");
const FakeCore = @import("fake_core.zig").FakeCore;
const memmap = ra8.chip.core.memmap;
const fault_status = ra8.chip.periph.fault_status;
const secure = fault_status.secure;
const route = fault_status.route;
const Nvic = ra8.chip.periph.nvic.Nvic;

const entry: u32 = memmap.sram_base + 0x2000;
const table: u32 = memmap.sram_base + 0x6000;
const handlers: u32 = memmap.sram_base + 0x7000;
const securefaultena: u32 = 1 << 19;

/// A fake core whose vector n points at `handlers + 0x10 * n`.
fn bench(shcsr: u32) !FakeCore {
    var core = FakeCore.init();
    errdefer core.deinit();
    try core.vectors(table, handlers);
    try core.writeWord(memmap.scb.vtor, table);
    try core.writeWord(memmap.scb.shcsr, shcsr);
    try core.setRegister(.sp, memmap.sram_base + 0x8000);
    return core;
}

test "SecureFault is exception 7, enabled by SHCSR bit 19, priority SHPR1 byte 3" {
    try std.testing.expectEqual(@as(u16, 7), route.exception(.secure_fault));
    try std.testing.expectEqual(securefaultena, route.enable(.secure_fault));
    try std.testing.expectEqual(@as(u8, 0xA0), route.priority(.secure_fault, 0xA000_0000));
}

test "an attribution violation latches AUVIOL, SFARVALID and SFAR" {
    const owed = secure.latch(.auviol, 0x2200_0040);
    try std.testing.expectEqual(@as(u32, (1 << 3) | (1 << 6)), owed.sfsr);
    try std.testing.expectEqual(@as(?u32, 0x2200_0040), owed.address);
}

test "an invalid entry point leaves SFAR alone" {
    const owed = secure.latch(.invep, 0x1234);
    try std.testing.expectEqual(@as(u32, 1 << 0), owed.sfsr);
    try std.testing.expectEqual(@as(?u32, null), owed.address);
}

test "an enabled SecureFault vectors to 7 with the instruction stacked" {
    var core = try bench(securefaultena);
    defer core.deinit();
    var unit = Nvic{};
    const taken = try secure.raise(&core, &unit, .auviol, 0x2200_0040, entry);
    try std.testing.expectEqual(@as(u16, 7), taken.number);
    try std.testing.expect(!taken.escalated);
    try std.testing.expectEqual(handlers + 0x70, try core.register(.pc));
    try std.testing.expectEqual(@as(u32, (1 << 3) | (1 << 6)), try core.readWord(secure.sfsr));
    try std.testing.expectEqual(@as(u32, 0x2200_0040), try core.readWord(secure.sfar));
    try std.testing.expectEqual(entry, try core.readWord((try core.register(.sp)) + 24));
    try std.testing.expectEqual(@as(u32, 0), try core.readWord(memmap.scb.cfsr));
}

test "a disabled SecureFault escalates with HFSR.FORCED and keeps SFSR" {
    var core = try bench(0);
    defer core.deinit();
    var unit = Nvic{};
    const taken = try secure.raise(&core, &unit, .invtran, 0, entry);
    try std.testing.expectEqual(@as(u16, 3), taken.number);
    try std.testing.expect(taken.escalated);
    try std.testing.expectEqual(@as(u32, 1 << 30), try core.readWord(memmap.scb.hfsr));
    try std.testing.expectEqual(@as(u32, 1 << 4), try core.readWord(secure.sfsr));
}
