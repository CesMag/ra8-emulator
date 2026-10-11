//! Covers src/chip/core/cpu/ops/mve_float_fma.zig. The encodings come from
//! LLVM's assembler for -mcpu=cortex-m85 with MVE floating point.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const mve_float_fma = ra8.chip.core.cpu.ops.mve.float.fma;
const qreg = ra8.chip.core.cpu.mve.qreg;
const decode = ra8.chip.core.cpu.decode;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = mve_float_fma.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

// q0 = 1.0, q1 = {1, 2, 3, 4} and q2 = 2.0 in every F32 lane.
fn loaded() Cpu {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 0, 0x3F800000_3F800000_3F800000_3F800000);
    qreg.write(&cpu.fp.bank, 1, 0x40800000_40400000_40000000_3F800000);
    qreg.write(&cpu.fp.bank, 2, 0x40000000_40000000_40000000_40000000);
    return cpu;
}

test "vfma.f32 q0, q1, q2 adds n*m to d" {
    var cpu = loaded();
    try run(&cpu, 0xEF02, 0x0C54);
    // {3, 5, 7, 9}
    try std.testing.expectEqual(@as(u128, 0x41100000_40E00000_40A00000_40400000), qreg.read(&cpu.fp.bank, 0));
}

test "vfms.f32 q0, q1, q2 subtracts n*m from d" {
    var cpu = loaded();
    try run(&cpu, 0xEF22, 0x0C54);
    // {-1, -3, -5, -7}
    try std.testing.expectEqual(@as(u128, 0xC0E00000_C0A00000_C0400000_BF800000), qreg.read(&cpu.fp.bank, 0));
}

test "vfms.f16 q3, q4, q1 runs every half lane" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 3, 0x3C00_3C00_3C00_3C00_3C00_3C00_3C00_3C00);
    qreg.write(&cpu.fp.bank, 4, 0x4000_4000_4000_4000_4000_4000_4000_4000);
    qreg.write(&cpu.fp.bank, 1, 0x3C00_3C00_3C00_3C00_3C00_3C00_3C00_3C00);
    try run(&cpu, 0xEF38, 0x6C52);
    // 1 - 2*1 = -1 in every lane.
    try std.testing.expectEqual(@as(u128, 0xBC00_BC00_BC00_BC00_BC00_BC00_BC00_BC00), qreg.read(&cpu.fp.bank, 3));
}

test "the table routes VFMA and VFMS here" {
    for ([_][2]u16{ .{ 0xEF02, 0x0C54 }, .{ 0xEF22, 0x0C54 }, .{ 0xEF1C, 0xEC5A }, .{ 0xEF38, 0x6C52 } }) |e| {
        const hit = decode.decode(wide(e[0], e[1])) orelse return error.NotClaimed;
        try std.testing.expectEqualStrings("mve_float_fma", hit.group);
    }
}

test "unclaimed: U set, a Q8+ register bit, or another tail" {
    try std.testing.expect(mve_float_fma.which(wide(0xFF02, 0x0C54)) == null);
    try std.testing.expect(mve_float_fma.which(wide(0xEF42, 0x0C54)) == null);
    try std.testing.expect(mve_float_fma.which(wide(0xEF02, 0x0C74)) == null);
    try std.testing.expect(mve_float_fma.which(wide(0xEF02, 0x0D44)) == null);
}
