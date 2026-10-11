//! Covers src/chip/core/cpu/ops/mve_bitwise.zig. The encodings come from LLVM's
//! assembler for -mcpu=cortex-m85 with MVE.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const mve_bitwise = ra8.chip.core.cpu.ops.mve.bitwise;
const qreg = ra8.chip.core.cpu.mve.qreg;
const decode = ra8.chip.core.cpu.decode;

const q1: u128 = 0xFFFF_0000_FF00_FF00_F0F0_F0F0_1234_5678;
const q2: u128 = 0x0F0F_0F0F_FFFF_0000_0000_FFFF_FFFF_0000;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = mve_bitwise.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

fn loaded() Cpu {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 1, q1);
    qreg.write(&cpu.fp.bank, 2, q2);
    return cpu;
}

test "vand, vbic, vorr, vorn and veor q0, q1, q2" {
    var cpu = loaded();
    const cases = [_]struct { hw1: u16, want: u128 }{
        .{ .hw1 = 0xEF02, .want = q1 & q2 },
        .{ .hw1 = 0xEF12, .want = q1 & ~q2 },
        .{ .hw1 = 0xEF22, .want = q1 | q2 },
        .{ .hw1 = 0xEF32, .want = q1 | ~q2 },
        .{ .hw1 = 0xFF02, .want = q1 ^ q2 },
    };
    for (cases) |case| {
        try run(&cpu, case.hw1, 0x0154);
        try std.testing.expectEqual(case.want, qreg.read(&cpu.fp.bank, 0));
    }
}

test "vmov q4, q1 is vorr q4, q1, q1" {
    var cpu = loaded();
    try run(&cpu, 0xEF22, 0x8152);
    try std.testing.expectEqual(q1, qreg.read(&cpu.fp.bank, 4));
}

test "inside vpste the first veor writes P0 lanes and the second the rest" {
    var cpu = loaded();
    cpu.fp.vpr = ra8.chip.core.cpu.mve.vpt.open(.{ .p0 = 0x00FF }, 0b1100);
    try run(&cpu, 0xFF02, 0x0154);
    try std.testing.expectEqual((q1 ^ q2) & 0xFFFF_FFFF_FFFF_FFFF, qreg.read(&cpu.fp.bank, 0));
    try run(&cpu, 0xFF02, 0x0154);
    try std.testing.expectEqual(q1 ^ q2, qreg.read(&cpu.fp.bank, 0));
    try std.testing.expect(!ra8.chip.core.cpu.mve.vpt.inBlock(cpu.fp.vpr));
}

test "the table routes the T1 encodings here" {
    for ([_]u16{ 0xEF02, 0xEF12, 0xEF22, 0xEF32, 0xFF02 }) |hw1| {
        const hit = decode.decode(wide(hw1, 0x0154)) orelse return error.NotClaimed;
        try std.testing.expectEqualStrings("mve_bitwise", hit.group);
    }
}

test "unclaimed: U with sz != 0, D/N/M set, other hw2" {
    for ([_]u16{ 0xFF12, 0xFF22, 0xFF32, 0xEF42 }) |hw1| {
        try std.testing.expect(mve_bitwise.group.decode(wide(hw1, 0x0154)) == null);
    }
    for ([_]u16{ 0x01D4, 0x0174, 0x0155, 0x0144, 0x0140 }) |hw2| {
        try std.testing.expect(mve_bitwise.group.decode(wide(0xEF22, hw2)) == null);
    }
}
