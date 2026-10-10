//! Tests for src/chip/periph/debug_monitor.zig, through the controllers dispatch
//! on a fake core.

const std = @import("std");
const ra8 = @import("ra8");
const FakeCore = @import("fake_core.zig").FakeCore;
const memmap = ra8.chip.core.memmap;
const debug_monitor = ra8.chip.periph.nvic.debug_monitor;
const Nvic = ra8.chip.periph.nvic.Nvic;

const entry: u32 = memmap.sram_base + 0x2000;
const table: u32 = memmap.sram_base + 0x6000;
const handlers: u32 = memmap.sram_base + 0x7000;
const mon_en: u32 = 1 << 16;
const mon_pend: u32 = 1 << 17;

/// A fake core whose vector n points at `handlers + 0x10 * n`, sitting at
/// the entry, with DEMCR set to `demcr`.
fn bench(demcr: u32) !FakeCore {
    var core = FakeCore.init();
    errdefer core.deinit();
    try core.vectors(table, handlers);
    try core.writeWord(memmap.scb.vtor, table);
    try core.writeWord(memmap.scb.demcr, demcr);
    try core.setRegister(.sp, memmap.sram_base + 0x8000);
    try core.setRegister(.pc, entry);
    return core;
}

test "MON_PEND with MON_EN enters DebugMonitor, clears the pend and sets MONITORACT" {
    var core = try bench(mon_en | mon_pend);
    defer core.deinit();
    var unit = Nvic{};
    try std.testing.expectEqual(@as(?u16, debug_monitor.number), try unit.dispatch(&core));
    try std.testing.expectEqual(handlers + 0x10 * debug_monitor.number, try core.register(.pc));
    try std.testing.expectEqual(mon_en, try core.readWord(memmap.scb.demcr));
    try std.testing.expect(try core.readWord(memmap.scb.shcsr) & debug_monitor.shcsr_monitoract != 0);
}

test "MON_PEND without MON_EN is not taken" {
    var core = try bench(mon_pend);
    defer core.deinit();
    var unit = Nvic{};
    try std.testing.expectEqual(@as(?u16, null), try unit.dispatch(&core));
    try std.testing.expectEqual(mon_pend, try core.readWord(memmap.scb.demcr));
}

test "DebugMonitor under PRIMASK stays pending" {
    var core = try bench(mon_en | mon_pend);
    defer core.deinit();
    try core.setRegister(.primask, 1);
    var unit = Nvic{};
    try std.testing.expectEqual(@as(?u16, null), try unit.dispatch(&core));
    try std.testing.expectEqual(mon_en | mon_pend, try core.readWord(memmap.scb.demcr));
}

test "pending reads PRI_12 from the low byte of SHPR3" {
    var core = try bench(mon_en | mon_pend);
    defer core.deinit();
    try core.writeWord(memmap.scb.shpr3, 0x00C0_0060);
    const candidate = (try debug_monitor.pending(&core)) orelse return error.NotPending;
    try std.testing.expectEqual(@as(u8, 0x60), candidate.priority);
    try debug_monitor.setActive(&core, true);
    try debug_monitor.setActive(&core, false);
    try std.testing.expectEqual(@as(u32, 0), try core.readWord(memmap.scb.shcsr));
}
