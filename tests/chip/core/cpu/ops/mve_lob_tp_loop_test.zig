//! Covers src/chip/core/cpu/ops/mve/lob_tp.zig end to end: tail-predicated loops
//! stepped through Cpu.step from RAM, with a remainder on the last
//! iteration. The listing comes from LLVM's assembler for -mcpu=cortex-m85
//! with MVE:
//!
//!   0x100  dlstp.32 lr, r0
//!   0x104  vadd.i32 q0, q0, q1
//!   0x108  letp lr, 0x104
//!   0x10C  wlstp.16 lr, r1, 0x118
//!   0x110  vadd.i16 q2, q2, q1
//!   0x114  letp lr, 0x110
//!   0x118  nop
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const qreg = ra8.chip.core.cpu.mve.qreg;
const fixture = @import("../exception/ram.zig");

const listing = [_]u16{ 0xF020, 0xE001, 0xEF20, 0x0842, 0xF01F, 0xC005, 0xF011, 0xC005, 0xEF14, 0x4842, 0xF01F, 0xC005, 0xBF00 };
const ones: u128 = 0x0001_0001_0001_0001_0001_0001_0001_0001;

fn load(ram: *fixture.Ram) !Cpu {
    for (listing, 0..) |half, i| ram.putHalf(fixture.code + @as(u32, @intCast(i)) * 2, half);
    var cpu = try fixture.boot(ram);
    qreg.write(&cpu.fp.bank, 1, ones);
    return cpu;
}

fn steps(cpu: *Cpu, count: usize) !void {
    for (0..count) |_| if (cpu.step()) |stop| {
        std.debug.print("stopped at 0x{X}: {any}\n", .{ cpu.regs.pc, stop });
        return error.Stopped;
    };
}

test "a 10-word DLSTP loop runs 4, 4, then 2 elements and exits" {
    var ram: fixture.Ram = .{};
    var cpu = try load(&ram);
    cpu.regs.set(0, 10);
    try steps(&cpu, 7);
    try std.testing.expectEqual(fixture.code + 0x0C, cpu.regs.pc);
    try std.testing.expectEqual(@as(u128, 0x0002_0002_0002_0002_0003_0003_0003_0003), qreg.read(&cpu.fp.bank, 0));
    try std.testing.expectEqual(@as(u32, 2), cpu.regs.lr);
    try std.testing.expectEqual(@as(u3, 4), cpu.fp.fpscr.ltpsize);
}

test "an 11-halfword WLSTP loop runs 8, then 3 elements" {
    var ram: fixture.Ram = .{};
    var cpu = try load(&ram);
    cpu.regs.pc = fixture.code + 0x0C;
    cpu.regs.set(1, 11);
    try steps(&cpu, 5);
    try std.testing.expectEqual(fixture.code + 0x18, cpu.regs.pc);
    try std.testing.expectEqual(@as(u128, 0x0001_0001_0001_0001_0001_0002_0002_0002), qreg.read(&cpu.fp.bank, 2));
    try std.testing.expectEqual(@as(u32, 3), cpu.regs.lr);
    try std.testing.expectEqual(@as(u3, 4), cpu.fp.fpscr.ltpsize);
}

test "WLSTP with a zero count skips the body" {
    var ram: fixture.Ram = .{};
    var cpu = try load(&ram);
    cpu.regs.pc = fixture.code + 0x0C;
    cpu.regs.lr = 0x77;
    try steps(&cpu, 1);
    try std.testing.expectEqual(fixture.code + 0x18, cpu.regs.pc);
    try std.testing.expectEqual(@as(u128, 0), qreg.read(&cpu.fp.bank, 2));
    try std.testing.expectEqual(@as(u32, 0x77), cpu.regs.lr);
}

test "an exact multiple runs whole vectors only" {
    var ram: fixture.Ram = .{};
    var cpu = try load(&ram);
    cpu.regs.set(0, 8);
    try steps(&cpu, 5);
    try std.testing.expectEqual(fixture.code + 0x0C, cpu.regs.pc);
    try std.testing.expectEqual(@as(u128, 0x0002_0002_0002_0002_0002_0002_0002_0002), qreg.read(&cpu.fp.bank, 0));
}
