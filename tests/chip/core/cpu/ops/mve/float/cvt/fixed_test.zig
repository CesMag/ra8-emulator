//! Covers src/chip/core/cpu/ops/mve_float_cvt_fixed.zig. The encodings come from
//! LLVM's assembler for -mcpu=cortex-m85 with MVE floating point.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const cvt = ra8.chip.core.cpu.ops.mve_float_cvt_fixed;
const qreg = ra8.chip.core.cpu.mve.qreg;
const decode = ra8.chip.core.cpu.decode;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = cvt.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

test "vcvt.f32.s32 q0, q1, #1 and vcvt.f32.u32 q0, q1, #32" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 1, 0x80000000_00000000_FFFFFFFF_00000003);
    try run(&cpu, 0xEFBF, 0x0E52);
    // {1.5, -0.5, 0, -2^30}
    try std.testing.expectEqual(@as(u128, 0xCE800000_00000000_BF000000_3FC00000), qreg.read(&cpu.fp.bank, 0));
    try run(&cpu, 0xFFA0, 0x0E52);
    // 0x80000000 unsigned with 32 fraction bits is 0.5.
    try std.testing.expectEqual(@as(u32, 0x3F000000), @as(u32, @truncate(qreg.read(&cpu.fp.bank, 0) >> 96)));
}

test "vcvt.s32.f32 q0, q1, #16 and vcvt.u32.f32 q7, q6, #3 round toward zero" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 1, 0x00000000_00000000_BF000000_3FC00000);
    try run(&cpu, 0xEFB0, 0x0F52);
    try std.testing.expectEqual(@as(u128, 0x00000000_00000000_FFFF8000_00018000), qreg.read(&cpu.fp.bank, 0));
    qreg.write(&cpu.fp.bank, 6, 0x40100000_40100000_40100000_40100000);
    try run(&cpu, 0xFFBD, 0xEF5C);
    try std.testing.expectEqual(@as(u128, 0x00000012_00000012_00000012_00000012), qreg.read(&cpu.fp.bank, 7));
}

test "F16 forms: vcvt.f16.s16 #1, vcvt.s16.f16 q2, q4, #8, and a saturating vcvt.u16.f16 #2" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 1, 0x0003_0003_0003_0003_0003_0003_0003_0003);
    try run(&cpu, 0xEFBF, 0x0C52);
    try std.testing.expectEqual(@as(u128, 0x3E00_3E00_3E00_3E00_3E00_3E00_3E00_3E00), qreg.read(&cpu.fp.bank, 0));
    qreg.write(&cpu.fp.bank, 4, 0xB800_3E00_B800_3E00_B800_3E00_B800_3E00);
    try run(&cpu, 0xEFB8, 0x4D58);
    try std.testing.expectEqual(@as(u128, 0xFF80_0180_FF80_0180_FF80_0180_FF80_0180), qreg.read(&cpu.fp.bank, 2));
    qreg.write(&cpu.fp.bank, 1, 0x7BFF_7BFF_7BFF_7BFF_7BFF_7BFF_7BFF_7BFF);
    try run(&cpu, 0xFFBE, 0x0D52);
    try std.testing.expectEqual(@as(u128, 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF), qreg.read(&cpu.fp.bank, 0));
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.fpscr.ioc);
}

test "the table routes every form here" {
    const all = [_][2]u16{
        .{ 0xEFBF, 0x0E52 }, .{ 0xFFA0, 0x0E52 }, .{ 0xEFB0, 0x0F52 }, .{ 0xFFBD, 0xEF5C },
        .{ 0xEFBF, 0x0C52 }, .{ 0xFFB0, 0x0C52 }, .{ 0xEFB8, 0x4D58 }, .{ 0xFFBE, 0x0D52 },
    };
    for (all) |e| {
        const hit = decode.decode(wide(e[0], e[1])) orelse return error.NotClaimed;
        try std.testing.expectEqualStrings("mve_float_cvt_fixed", hit.group);
    }
}

test "unclaimed: an F32 imm6 below 32, an F16 imm6 below 48, D or M set" {
    try std.testing.expect(cvt.fields(wide(0xEF9F, 0x0E52)) == null);
    try std.testing.expect(cvt.fields(wide(0xEFA8, 0x0C52)) == null);
    try std.testing.expect(cvt.fields(wide(0xEFFF, 0x0E52)) == null);
    try std.testing.expect(cvt.fields(wide(0xEFBF, 0x0E72)) == null);
}
