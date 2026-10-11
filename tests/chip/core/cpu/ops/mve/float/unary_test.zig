//! Covers src/chip/core/cpu/ops/mve_float_unary.zig. The encodings come from
//! LLVM's assembler for -mcpu=cortex-m85 with MVE floating point.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const mve_float_unary = ra8.chip.core.cpu.ops.mve.float.unary;
const qreg = ra8.chip.core.cpu.mve.qreg;
const decode = ra8.chip.core.cpu.decode;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = mve_float_unary.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

// q1 = {-1.0, 2.0, -0.0, signalling NaN with the sign set} as F32.
const mixed: u128 = 0xFF800001_80000000_40000000_BF800000;

test "vabs.f32 q0, q1 clears every sign bit and keeps a NaN payload" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 1, mixed);
    try run(&cpu, 0xFFB9, 0x0742);
    try std.testing.expectEqual(@as(u128, 0x7F800001_00000000_40000000_3F800000), qreg.read(&cpu.fp.bank, 0));
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.fpscr.ioc);
}

test "vneg.f32 q0, q1 flips every sign bit" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 1, mixed);
    try run(&cpu, 0xFFB9, 0x07C2);
    try std.testing.expectEqual(@as(u128, 0x7F800001_00000000_C0000000_3F800000), qreg.read(&cpu.fp.bank, 0));
}

test "vneg.f16 q3, q5 and vabs.f16 q7, q6 work on half lanes" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 5, 0x3C00_BC00_3C00_BC00_3C00_BC00_3C00_BC00);
    try run(&cpu, 0xFFB5, 0x67CA);
    try std.testing.expectEqual(@as(u128, 0xBC00_3C00_BC00_3C00_BC00_3C00_BC00_3C00), qreg.read(&cpu.fp.bank, 3));
    qreg.write(&cpu.fp.bank, 6, 0xBC00_BC00_BC00_BC00_BC00_BC00_BC00_BC00);
    try run(&cpu, 0xFFB5, 0xE74C);
    try std.testing.expectEqual(@as(u128, 0x3C00_3C00_3C00_3C00_3C00_3C00_3C00_3C00), qreg.read(&cpu.fp.bank, 7));
}

test "the table routes the float forms here and integer VABS elsewhere" {
    for ([_][2]u16{ .{ 0xFFB9, 0x0742 }, .{ 0xFFB9, 0x07C2 }, .{ 0xFFB5, 0xE74C }, .{ 0xFFB5, 0x67CA } }) |e| {
        const hit = decode.decode(wide(e[0], e[1])) orelse return error.NotClaimed;
        try std.testing.expectEqualStrings("mve_float_unary", hit.group);
    }
    try std.testing.expect(mve_float_unary.fields(wide(0xFFB9, 0x0342)) == null);
}

test "unclaimed: size 0 or 3, D set, or M set" {
    try std.testing.expect(mve_float_unary.fields(wide(0xFFB1, 0x0742)) == null);
    try std.testing.expect(mve_float_unary.fields(wide(0xFFBD, 0x0742)) == null);
    try std.testing.expect(mve_float_unary.fields(wide(0xFFF9, 0x0742)) == null);
    try std.testing.expect(mve_float_unary.fields(wide(0xFFB9, 0x0762)) == null);
}
