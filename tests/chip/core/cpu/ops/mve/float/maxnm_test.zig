//! Covers src/chip/core/cpu/ops/mve_float_maxnm.zig. The encodings come from
//! LLVM's assembler for -mcpu=cortex-m85 with MVE floating point.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const maxnm = ra8.chip.core.cpu.ops.mve.float.maxnm;
const qreg = ra8.chip.core.cpu.mve.qreg;
const decode = ra8.chip.core.cpu.decode;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = maxnm.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

// q1 = {1, -0, quiet NaN, 5} and q2 = {2, +0, 3, -1} as F32.
fn loaded() Cpu {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 1, 0x40A00000_7FC00000_80000000_3F800000);
    qreg.write(&cpu.fp.bank, 2, 0xBF800000_40400000_00000000_40000000);
    return cpu;
}

test "vmaxnm.f32 q0, q1, q2 picks the number over a quiet NaN and +0 over -0" {
    var cpu = loaded();
    try run(&cpu, 0xFF02, 0x0F54);
    try std.testing.expectEqual(@as(u128, 0x40A00000_40400000_00000000_40000000), qreg.read(&cpu.fp.bank, 0));
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.fpscr.ioc);
}

test "vminnm.f32 q0, q1, q2 picks -0 over +0" {
    var cpu = loaded();
    try run(&cpu, 0xFF22, 0x0F54);
    try std.testing.expectEqual(@as(u128, 0xBF800000_40400000_80000000_3F800000), qreg.read(&cpu.fp.bank, 0));
}

test "F16 forms: vmaxnm.f16 q7, q6, q5 and vminnm.f16 q3, q4, q1" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 6, 0x3C00_C000_3C00_C000_3C00_C000_3C00_C000);
    qreg.write(&cpu.fp.bank, 5, 0x4000_BC00_4000_BC00_4000_BC00_4000_BC00);
    try run(&cpu, 0xFF1C, 0xEF5A);
    try std.testing.expectEqual(@as(u128, 0x4000_BC00_4000_BC00_4000_BC00_4000_BC00), qreg.read(&cpu.fp.bank, 7));
    qreg.write(&cpu.fp.bank, 4, 0x3C00_C000_3C00_C000_3C00_C000_3C00_C000);
    qreg.write(&cpu.fp.bank, 1, 0x4000_BC00_4000_BC00_4000_BC00_4000_BC00);
    try run(&cpu, 0xFF38, 0x6F52);
    try std.testing.expectEqual(@as(u128, 0x3C00_C000_3C00_C000_3C00_C000_3C00_C000), qreg.read(&cpu.fp.bank, 3));
}

test "the table routes all four forms here" {
    for ([_][2]u16{ .{ 0xFF02, 0x0F54 }, .{ 0xFF22, 0x0F54 }, .{ 0xFF1C, 0xEF5A }, .{ 0xFF38, 0x6F52 } }) |e| {
        const hit = decode.decode(wide(e[0], e[1])) orelse return error.NotClaimed;
        try std.testing.expectEqualStrings("mve_float_maxnm", hit.group);
    }
}

test "unclaimed: U clear, D, N or M set" {
    try std.testing.expect(maxnm.which(wide(0xEF02, 0x0F54)) == null);
    try std.testing.expect(maxnm.which(wide(0xFF42, 0x0F54)) == null);
    try std.testing.expect(maxnm.which(wide(0xFF02, 0x0FD4)) == null);
    try std.testing.expect(maxnm.which(wide(0xFF02, 0x0F74)) == null);
}
