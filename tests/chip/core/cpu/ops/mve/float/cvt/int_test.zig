//! Covers src/chip/core/cpu/ops/mve_float_cvt_int.zig. The encodings come from
//! LLVM's assembler for -mcpu=cortex-m85 with MVE floating point.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const cvt = ra8.chip.core.cpu.ops.mve.float.cvt.int;
const qreg = ra8.chip.core.cpu.mve.qreg;
const decode = ra8.chip.core.cpu.decode;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16, q1: u128) !u128 {
    qreg.write(&cpu.fp.bank, 1, q1);
    const instr = wide(hw1, hw2);
    const exec = cvt.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
    return qreg.read(&cpu.fp.bank, 0);
}

// {2.5, -2.5, 1.5, -0.5} as F32.
const halves: u128 = 0xBF000000_3FC00000_C0200000_40200000;

test "vcvt.f32.s32 and vcvt.f32.u32 q0, q1" {
    var cpu: Cpu = .{ .bus = undefined };
    // {1, -1, 3, 0} signed.
    try std.testing.expectEqual(@as(u128, 0x00000000_40400000_BF800000_3F800000), try run(&cpu, 0xFFBB, 0x0642, 0x00000000_00000003_FFFFFFFF_00000001));
    // 0xFFFFFFFF unsigned rounds to 2^32.
    try std.testing.expectEqual(@as(u128, 0x4F800000), try run(&cpu, 0xFFBB, 0x06C2, 0xFFFFFFFF));
}

test "vcvt.s32.f32 and vcvt.u32.f32 round toward zero" {
    var cpu: Cpu = .{ .bus = undefined };
    try std.testing.expectEqual(@as(u128, 0x00000000_00000001_FFFFFFFE_00000002), try run(&cpu, 0xFFBB, 0x0742, halves));
    // Negative lanes saturate to 0 unsigned and raise IOC.
    try std.testing.expectEqual(@as(u128, 0x00000000_00000001_00000000_00000002), try run(&cpu, 0xFFBB, 0x07C2, halves));
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.fpscr.ioc);
}

test "vcvta, vcvtn and vcvtp pick their rounding" {
    var cpu: Cpu = .{ .bus = undefined };
    // Ties away: {3, -3, 2, -1}.
    try std.testing.expectEqual(@as(u128, 0xFFFFFFFF_00000002_FFFFFFFD_00000003), try run(&cpu, 0xFFBB, 0x0042, halves));
    // Toward +inf: {3, -2, 2, 0}.
    try std.testing.expectEqual(@as(u128, 0x00000000_00000002_FFFFFFFE_00000003), try run(&cpu, 0xFFBB, 0x0242, halves));
    // Nearest even, unsigned: {2, 0, 2, 0}.
    try std.testing.expectEqual(@as(u128, 0x00000000_00000002_00000000_00000002), try run(&cpu, 0xFFBB, 0x01C2, halves));
}

test "F16 forms: vcvt.f16.s16 q7, q6 and vcvtm.u16.f16 q2, q4" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 6, 0x0001_FFFF_0002_FFFE_0003_FFFD_0004_FFFC);
    var instr = wide(0xFFB7, 0xE64C);
    try (cvt.group.decode(instr) orelse return error.NotClaimed)(&cpu, instr);
    try std.testing.expectEqual(@as(u128, 0x3C00_BC00_4000_C000_4200_C200_4400_C400), qreg.read(&cpu.fp.bank, 7));
    // 1.5 rounds down to 1 in every lane.
    qreg.write(&cpu.fp.bank, 4, 0x3E00_3E00_3E00_3E00_3E00_3E00_3E00_3E00);
    instr = wide(0xFFB7, 0x43C8);
    try (cvt.group.decode(instr) orelse return error.NotClaimed)(&cpu, instr);
    try std.testing.expectEqual(@as(u128, 0x0001_0001_0001_0001_0001_0001_0001_0001), qreg.read(&cpu.fp.bank, 2));
}

test "the table routes every form here" {
    const all = [_][2]u16{
        .{ 0xFFBB, 0x0642 }, .{ 0xFFBB, 0x06C2 }, .{ 0xFFBB, 0x0742 }, .{ 0xFFBB, 0x07C2 }, .{ 0xFFB7, 0xE64C },
        .{ 0xFFB7, 0x67CA }, .{ 0xFFBB, 0x0042 }, .{ 0xFFBB, 0x01C2 }, .{ 0xFFBB, 0x0242 }, .{ 0xFFB7, 0x43C8 },
    };
    for (all) |e| {
        const hit = decode.decode(wide(e[0], e[1])) orelse return error.NotClaimed;
        try std.testing.expectEqualStrings("mve_float_cvt_int", hit.group);
    }
}

test "unclaimed: size 0 or 3, D or M set" {
    try std.testing.expect(cvt.fields(wide(0xFFB3, 0x0642)) == null);
    try std.testing.expect(cvt.fields(wide(0xFFBF, 0x0642)) == null);
    try std.testing.expect(cvt.fields(wide(0xFFFB, 0x0642)) == null);
    try std.testing.expect(cvt.fields(wide(0xFFBB, 0x0662)) == null);
    try std.testing.expect(cvt.fields(wide(0xFFBB, 0x0062)) == null);
}
