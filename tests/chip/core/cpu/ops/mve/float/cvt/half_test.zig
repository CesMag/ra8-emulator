//! Covers src/chip/core/cpu/ops/mve_float_cvt_half.zig. The encodings come from
//! LLVM's assembler for -mcpu=cortex-m85 with MVE floating point.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const cvt = ra8.chip.core.cpu.ops.mve.float.cvt.half;
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

// q0 starts as 0xAAAA in every half; q1 = {1, -2, 0.5, 65520} as F32.
fn loaded() Cpu {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 0, 0xAAAAAAAA_AAAAAAAA_AAAAAAAA_AAAAAAAA);
    qreg.write(&cpu.fp.bank, 1, 0x477FF000_3F000000_C0000000_3F800000);
    return cpu;
}

test "vcvtb.f16.f32 q0, q1 writes the bottom halves and keeps the tops" {
    var cpu = loaded();
    try run(&cpu, 0xEE3F, 0x0E03);
    // 65520 rounds to infinity and raises OFC and IXC.
    try std.testing.expectEqual(@as(u128, 0xAAAA7C00_AAAA3800_AAAAC000_AAAA3C00), qreg.read(&cpu.fp.bank, 0));
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.fpscr.ofc);
}

test "vcvtt.f16.f32 q0, q1 writes the top halves and keeps the bottoms" {
    var cpu = loaded();
    try run(&cpu, 0xEE3F, 0x1E03);
    try std.testing.expectEqual(@as(u128, 0x7C00AAAA_3800AAAA_C000AAAA_3C00AAAA), qreg.read(&cpu.fp.bank, 0));
}

test "vcvtb.f32.f16 q0, q1 and vcvtt.f32.f16 q7, q6 widen the chosen half" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 1, 0x3800_3C00_C000_3800_3C00_C000_4000_3C00);
    try run(&cpu, 0xFE3F, 0x0E03);
    try std.testing.expectEqual(@as(u128, 0x3F800000_3F000000_C0000000_3F800000), qreg.read(&cpu.fp.bank, 0));
    qreg.write(&cpu.fp.bank, 6, 0x3800_3C00_C000_3800_3C00_C000_4000_3C00);
    try run(&cpu, 0xFE3F, 0xFE0D);
    try std.testing.expectEqual(@as(u128, 0x3F000000_C0000000_3F800000_40000000), qreg.read(&cpu.fp.bank, 7));
}

test "the table routes all four forms here" {
    for ([_][2]u16{ .{ 0xEE3F, 0x0E03 }, .{ 0xEE3F, 0x1E03 }, .{ 0xFE3F, 0x0E03 }, .{ 0xFE3F, 0xFE0D } }) |e| {
        const hit = decode.decode(wide(e[0], e[1])) orelse return error.NotClaimed;
        try std.testing.expectEqualStrings("mve_float_cvt_half", hit.group);
    }
}

test "unclaimed: D or M set, or the VMAXNMA tail" {
    try std.testing.expect(cvt.fields(wide(0xEE7F, 0x0E03)) == null);
    try std.testing.expect(cvt.fields(wide(0xEE3F, 0x0E23)) == null);
    try std.testing.expect(cvt.fields(wide(0xEE3F, 0x0E83)) == null);
}
