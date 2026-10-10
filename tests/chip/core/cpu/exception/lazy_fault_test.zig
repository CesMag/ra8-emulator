//! Covers src/chip/core/cpu/exception/lazy_fault.zig through Cpu.step: a
//! deferred FP push the bus refuses is BusFault LSPERR when the lazy entry
//! recorded BFRDY, HardFault FORCED when only HFRDY, lockup when neither.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("ram.zig");
const memmap = ra8.chip.core.memmap;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Stop = ra8.chip.core.cpu.cpu.Stop;

const hard_handler: u32 = fixture.base + 0x1E0;
const bus_handler: u32 = fixture.base + 0x1C0;
const busfaultena: u32 = 1 << 17;
const lsperr: u32 = 1 << 13;
const forced: u32 = 1 << 30;
const unmapped: u32 = 0x1000_0000;
const bfar: u32 = 0xE000_ED38;

/// VADD.F32 s0, s1, s2 with a deferred FP push pending into `fpcar`; the
/// lazy entry recorded `bfrdy` and `hfrdy`.
fn lazyStep(ram: *fixture.Ram, shcsr: u32, fpcar: u32, bfrdy: u1, hfrdy: u1) !?Stop {
    ram.putWord(fixture.base + 3 * 4, hard_handler | 1);
    ram.putWord(fixture.base + 5 * 4, bus_handler | 1);
    ram.putWord(memmap.scb.shcsr, shcsr);
    ram.putHalf(fixture.code, 0xEE30);
    ram.putHalf(fixture.code + 2, 0x0A81);
    var cpu = try fixture.boot(ram);
    cpu.fp.context.writeFpcar(fpcar);
    cpu.fp.context.fpccr.lspact = 1;
    cpu.fp.context.fpccr.bfrdy = bfrdy;
    cpu.fp.context.fpccr.hfrdy = hfrdy;
    const stop = cpu.step();
    last = cpu;
    return stop;
}

var last: Cpu = undefined;

test "BFRDY set: a refused deferred push is BusFault LSPERR, the FP op stacked" {
    var ram: fixture.Ram = .{};
    try std.testing.expectEqual(@as(?Stop, null), try lazyStep(&ram, busfaultena, unmapped, 1, 1));
    try std.testing.expectEqual(bus_handler, last.regs.pc);
    try std.testing.expectEqual(@as(u32, 5), last.regs.xpsr & 0x1FF);
    try std.testing.expectEqual(lsperr, ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(@as(u32, 0), ram.word(bfar));
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.hfsr));
    try std.testing.expectEqual(@as(u1, 1), last.fp.context.fpccr.lspact);
    try std.testing.expectEqual(fixture.code, ram.word(fixture.msp_top - 8));
}

test "the RDY bit the entry recorded wins over a BUSFAULTENA cleared since" {
    var ram: fixture.Ram = .{};
    try std.testing.expectEqual(@as(?Stop, null), try lazyStep(&ram, 0, unmapped, 1, 1));
    try std.testing.expectEqual(bus_handler, last.regs.pc);
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.hfsr));
}

test "BFRDY clear with HFRDY set escalates LSPERR to HardFault FORCED" {
    var ram: fixture.Ram = .{};
    try std.testing.expectEqual(@as(?Stop, null), try lazyStep(&ram, busfaultena, unmapped, 0, 1));
    try std.testing.expectEqual(hard_handler, last.regs.pc);
    try std.testing.expectEqual(lsperr, ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(forced, ram.word(memmap.scb.hfsr));
}

test "BFRDY and HFRDY both clear locks up" {
    var ram: fixture.Ram = .{};
    const stop = try lazyStep(&ram, busfaultena, unmapped, 0, 0);
    try std.testing.expect(stop != null);
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.cfsr));
}

test "a push into mapped memory lands and the FP op runs" {
    var ram: fixture.Ram = .{};
    try std.testing.expectEqual(@as(?Stop, null), try lazyStep(&ram, busfaultena, fixture.msp_top - 0x60, 0, 0));
    try std.testing.expectEqual(fixture.code + 4, last.regs.pc);
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(@as(u1, 0), last.fp.context.fpccr.lspact);
}
