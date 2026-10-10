//! Covers src/chip/core/cpu/ops/mve_float_maxnma.zig. The encodings come from
//! LLVM's assembler for -mcpu=cortex-m85 with MVE floating point.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const maxnma = ra8.chip.core.cpu.ops.mve_float_maxnma;
const qreg = ra8.chip.core.cpu.mve.qreg;
const decode = ra8.chip.core.cpu.decode;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = maxnma.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

// q0 = {-3, 1, 2, -0} and q1 = {2, -4, -1, 0.5} as F32.
fn loaded() Cpu {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 0, 0x80000000_40000000_3F800000_C0400000);
    qreg.write(&cpu.fp.bank, 1, 0x3F000000_BF800000_C0800000_40000000);
    return cpu;
}

test "vmaxnma.f32 q0, q1 takes the larger magnitude, sign cleared" {
    var cpu = loaded();
    try run(&cpu, 0xEE3F, 0x0E83);
    try std.testing.expectEqual(@as(u128, 0x3F000000_40000000_40800000_40400000), qreg.read(&cpu.fp.bank, 0));
}

test "vminnma.f32 q0, q1 takes the smaller magnitude, so |-0| is +0" {
    var cpu = loaded();
    try run(&cpu, 0xEE3F, 0x1E83);
    try std.testing.expectEqual(@as(u128, 0x00000000_3F800000_3F800000_40000000), qreg.read(&cpu.fp.bank, 0));
}

test "F16 forms: vmaxnma.f16 q7, q6 and vminnma.f16 q3, q5" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 7, 0xC000_C000_C000_C000_C000_C000_C000_C000);
    qreg.write(&cpu.fp.bank, 6, 0x3C00_3C00_3C00_3C00_3C00_3C00_3C00_3C00);
    try run(&cpu, 0xFE3F, 0xEE8D);
    try std.testing.expectEqual(@as(u128, 0x4000_4000_4000_4000_4000_4000_4000_4000), qreg.read(&cpu.fp.bank, 7));
    qreg.write(&cpu.fp.bank, 3, 0xC000_C000_C000_C000_C000_C000_C000_C000);
    qreg.write(&cpu.fp.bank, 5, 0xBC00_BC00_BC00_BC00_BC00_BC00_BC00_BC00);
    try run(&cpu, 0xFE3F, 0x7E8B);
    try std.testing.expectEqual(@as(u128, 0x3C00_3C00_3C00_3C00_3C00_3C00_3C00_3C00), qreg.read(&cpu.fp.bank, 3));
}

test "the table routes all four forms here, and VCVTB still goes elsewhere" {
    for ([_][2]u16{ .{ 0xEE3F, 0x0E83 }, .{ 0xEE3F, 0x1E83 }, .{ 0xFE3F, 0xEE8D }, .{ 0xFE3F, 0x7E8B } }) |e| {
        const hit = decode.decode(wide(e[0], e[1])) orelse return error.NotClaimed;
        try std.testing.expectEqualStrings("mve_float_maxnma", hit.group);
    }
    const cvt = decode.decode(wide(0xEE3F, 0x0E03)) orelse return error.NotClaimed;
    try std.testing.expectEqualStrings("mve_float_cvt_half", cvt.group);
}

test "unclaimed: D or M set, bit 7 clear" {
    try std.testing.expect(maxnma.which(wide(0xEE7F, 0x0E83)) == null);
    try std.testing.expect(maxnma.which(wide(0xEE3F, 0x0EA3)) == null);
    try std.testing.expect(maxnma.which(wide(0xEE3F, 0x0E03)) == null);
}
