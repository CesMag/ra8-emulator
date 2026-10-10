//! Tests for src/chip/periph/usage_fault.zig, against a fake core.

const std = @import("std");
const ra8 = @import("ra8");
const FakeCore = @import("fake_core.zig").FakeCore;
const memmap = ra8.chip.core.memmap;
const fault_status = ra8.chip.periph.fault_status;
const usage = fault_status.usage;
const Nvic = ra8.chip.periph.nvic.Nvic;

const entry: u32 = memmap.sram_base + 0x2000;
const table: u32 = memmap.sram_base + 0x6000;
const handlers: u32 = memmap.sram_base + 0x7000;

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

test "an undefined instruction with UsageFault enabled vectors to 6" {
    var core = try bench(1 << 18);
    defer core.deinit();
    var unit = Nvic{};
    const taken = try usage.raise(&core, &unit, .undefinstr, entry);
    try std.testing.expectEqual(@as(u16, 6), taken.number);
    try std.testing.expect(!taken.escalated);
    try std.testing.expectEqual(handlers + 0x60, try core.register(.pc));
    try std.testing.expectEqual(@as(u32, 1 << 16), try core.readWord(memmap.scb.cfsr));
    try std.testing.expectEqual(entry, try core.readWord((try core.register(.sp)) + 24));
}

test "a UsageFault with USGFAULTENA clear escalates with HFSR.FORCED" {
    var core = try bench(0);
    defer core.deinit();
    var unit = Nvic{};
    const taken = try usage.raise(&core, &unit, .divbyzero, entry);
    try std.testing.expectEqual(@as(u16, 3), taken.number);
    try std.testing.expect(taken.escalated);
    try std.testing.expectEqual(@as(u32, 1 << 30), try core.readWord(memmap.scb.hfsr));
    try std.testing.expectEqual(@as(u32, 1 << 25), try core.readWord(memmap.scb.cfsr));
}

test "UFSR bits from earlier faults are kept" {
    var core = try bench(1 << 18);
    defer core.deinit();
    try core.writeWord(memmap.scb.cfsr, 1 << 17);
    var unit = Nvic{};
    _ = try usage.raise(&core, &unit, .nocp, entry);
    try std.testing.expectEqual(@as(u32, (1 << 17) | (1 << 19)), try core.readWord(memmap.scb.cfsr));
}

test "a MemManage or BusFault cause is refused and latches nothing" {
    var core = try bench(1 << 18);
    defer core.deinit();
    var unit = Nvic{};
    try std.testing.expectError(usage.Error.NotUsageFault, usage.raise(&core, &unit, .preciserr, entry));
    try std.testing.expectError(usage.Error.NotUsageFault, usage.raise(&core, &unit, .daccviol, entry));
    try std.testing.expectEqual(@as(u32, 0), try core.readWord(memmap.scb.cfsr));
    try std.testing.expectEqual(@as(u8, 0), unit.depth);
}
