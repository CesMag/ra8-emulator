//! Covers src/chip/core/cpu/exception/secure.zig.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("ram.zig");
const memmap = ra8.chip.core.memmap;
const secure = ra8.chip.core.cpu.exception.secure;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;

const secure_handler: u32 = fixture.base + 0x1C0;
const hard_handler: u32 = fixture.base + 0x1E0;
const securefaultena: u32 = 1 << 19;
const sfsr: u32 = 0xE000_EDE4;
const sfar: u32 = 0xE000_EDE8;
const invep: u32 = 1 << 0;
const auviol: u32 = 1 << 3;
const sfarvalid: u32 = 1 << 6;
const forced: u32 = 1 << 30;

fn booted(ram: *fixture.Ram) !Cpu {
    ram.putWord(fixture.base + 3 * 4, hard_handler | 1);
    ram.putWord(fixture.base + 7 * 4, secure_handler | 1);
    return fixture.boot(ram);
}

fn ipsr(cpu: *const Cpu) u32 {
    return cpu.regs.xpsr & 0x1FF;
}

test "INVEP is taken as SecureFault when SECUREFAULTENA is set" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, securefaultena);
    var cpu = try booted(&ram);
    try secure.raise(&cpu, .invep, fixture.code, 0);
    try std.testing.expectEqual(secure_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 7), ipsr(&cpu));
    try std.testing.expectEqual(invep, ram.word(sfsr));
    try std.testing.expectEqual(@as(u32, 0), ram.word(sfar));
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.hfsr));
    // The faulting instruction is the stacked return address.
    try std.testing.expectEqual(fixture.code, ram.word(cpu.regs.sp() + 24));
}

test "with SECUREFAULTENA clear it escalates to HardFault and keeps SFSR" {
    var ram: fixture.Ram = .{};
    var cpu = try booted(&ram);
    try secure.raise(&cpu, .invep, fixture.code, 0);
    try std.testing.expectEqual(hard_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 3), ipsr(&cpu));
    try std.testing.expectEqual(invep, ram.word(sfsr));
    try std.testing.expectEqual(forced, ram.word(memmap.scb.hfsr));
}

test "AUVIOL reports its address in SFAR with SFARVALID" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, securefaultena);
    var cpu = try booted(&ram);
    try secure.raise(&cpu, .auviol, fixture.code, 0x1000_0040);
    try std.testing.expectEqual(secure_handler, cpu.regs.pc);
    try std.testing.expectEqual(auviol | sfarvalid, ram.word(sfsr));
    try std.testing.expectEqual(@as(u32, 0x1000_0040), ram.word(sfar));
}

test "a SecureFault that cannot preempt from HardFault is lockup" {
    var ram: fixture.Ram = .{};
    var cpu = try booted(&ram);
    try secure.raise(&cpu, .invep, fixture.code, 0);
    try std.testing.expectError(error.Lockup, secure.raise(&cpu, .invep, hard_handler, 0));
}
