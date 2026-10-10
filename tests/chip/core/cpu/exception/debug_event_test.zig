//! Covers src/chip/core/cpu/exception/debug_event.zig through Cpu.step.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("ram.zig");
const memmap = ra8.chip.core.memmap;
const debug_event = ra8.chip.core.cpu.exception.debug_event;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Stop = ra8.chip.core.cpu.cpu.Stop;

const monitor_handler: u32 = fixture.base + 0x1C0;
const hard_handler: u32 = fixture.base + 0x1E0;
const debugevt: u32 = 1 << 31;

/// `bkpt #0` at the reset PC, with DebugMonitor and HardFault aimed at
/// their handlers.
fn booted(ram: *fixture.Ram) !Cpu {
    ram.putWord(fixture.base + 3 * 4, hard_handler | 1);
    ram.putWord(fixture.base + 12 * 4, monitor_handler | 1);
    ram.putWord(fixture.code, 0x0000_BE00);
    return fixture.boot(ram);
}

fn ipsr(cpu: *const Cpu) u32 {
    return cpu.regs.xpsr & 0x1FF;
}

test "with halting debug on, BKPT halts on itself and latches DFSR.BKPT" {
    var ram: fixture.Ram = .{};
    ram.putWord(debug_event.dhcsr, debug_event.c_debugen);
    var cpu = try booted(&ram);
    try std.testing.expectEqual(Stop{ .breakpoint = fixture.code }, cpu.step().?);
    try std.testing.expectEqual(fixture.code, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0), ipsr(&cpu));
    try std.testing.expectEqual(debug_event.dfsr_bkpt, ram.word(debug_event.dfsr));
}

test "with no debugger and MON_EN clear, BKPT escalates to HardFault with DEBUGEVT" {
    var ram: fixture.Ram = .{};
    var cpu = try booted(&ram);
    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(hard_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 3), ipsr(&cpu));
    try std.testing.expectEqual(debugevt, ram.word(memmap.scb.hfsr));
    try std.testing.expectEqual(debug_event.dfsr_bkpt, ram.word(debug_event.dfsr));
    // The BKPT itself is the stacked return address.
    try std.testing.expectEqual(fixture.code, ram.word(cpu.regs.sp() + 24));
}

test "with MON_EN set, BKPT takes DebugMonitor at its SHPR3 priority" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.demcr, debug_event.mon_en);
    ram.putWord(memmap.scb.shpr3, 0x40);
    var cpu = try booted(&ram);
    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(monitor_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 12), ipsr(&cpu));
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.hfsr));
    try std.testing.expectEqual(fixture.code, ram.word(cpu.regs.sp() + 24));
}

test "a DebugMonitor that cannot preempt escalates to HardFault" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.demcr, debug_event.mon_en);
    ram.putWord(memmap.scb.shpr3, 0x80);
    var cpu = try booted(&ram);
    cpu.regs.basepri = 0x40;
    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(hard_handler, cpu.regs.pc);
    try std.testing.expectEqual(debugevt, ram.word(memmap.scb.hfsr));
}

test "BKPT with FAULTMASK set locks up and stops on the BKPT" {
    var ram: fixture.Ram = .{};
    var cpu = try booted(&ram);
    cpu.regs.faultmask = 1;
    try std.testing.expectEqual(Stop{ .breakpoint = fixture.code }, cpu.step().?);
    try std.testing.expectEqual(fixture.code, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.hfsr));
}
