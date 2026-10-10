//! Covers src/chip/core/cpu/ops/mve_float_scalar.zig. The encodings come from
//! LLVM's assembler for -mcpu=cortex-m85 with MVE floating point.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const mve_float_scalar = ra8.chip.core.cpu.ops.mve_float_scalar;
const qreg = ra8.chip.core.cpu.mve.qreg;
const decode = ra8.chip.core.cpu.decode;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = mve_float_scalar.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

const ones: u128 = 0x3F800000_3F800000_3F800000_3F800000;

// q1 = {1, 2, 3, 4} as F32, low lane first, and r2 = 2.0.
fn loaded() Cpu {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 1, 0x40800000_40400000_40000000_3F800000);
    cpu.regs.set(2, 0x40000000);
    return cpu;
}

test "vadd, vsub and vmul .f32 q0, q1, r2" {
    var cpu = loaded();
    try run(&cpu, 0xEE32, 0x0F42);
    try std.testing.expectEqual(@as(u128, 0x40C00000_40A00000_40800000_40400000), qreg.read(&cpu.fp.bank, 0));
    try run(&cpu, 0xEE32, 0x1F42);
    try std.testing.expectEqual(@as(u128, 0x40000000_3F800000_00000000_BF800000), qreg.read(&cpu.fp.bank, 0));
    try run(&cpu, 0xEE33, 0x0E62);
    try std.testing.expectEqual(@as(u128, 0x41000000_40C00000_40800000_40000000), qreg.read(&cpu.fp.bank, 0));
}

test "vfma is d + n*r2 and vfmas is d*n + r2" {
    var cpu = loaded();
    qreg.write(&cpu.fp.bank, 0, ones);
    try run(&cpu, 0xEE33, 0x0E42);
    try std.testing.expectEqual(@as(u128, 0x41100000_40E00000_40A00000_40400000), qreg.read(&cpu.fp.bank, 0));
    qreg.write(&cpu.fp.bank, 0, ones);
    try run(&cpu, 0xEE33, 0x1E42);
    try std.testing.expectEqual(@as(u128, 0x40C00000_40A00000_40800000_40400000), qreg.read(&cpu.fp.bank, 0));
}

test "vmul.f16 q7, q1, r12 uses only the low half of r12" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 1, 0x4400_4200_4000_3C00_4400_4200_4000_3C00);
    cpu.regs.set(12, 0xABCD4000);
    try run(&cpu, 0xFE33, 0xEE6C);
    try std.testing.expectEqual(@as(u128, 0x4800_4600_4400_4000_4800_4600_4400_4000), qreg.read(&cpu.fp.bank, 7));
}

test "inside vpst only the P0 lanes are written" {
    var cpu = loaded();
    cpu.fp.vpr = ra8.chip.core.cpu.mve.vpt.open(.{ .p0 = 0xFF00 }, 0b1000);
    try run(&cpu, 0xEE32, 0x0F42);
    try std.testing.expectEqual(@as(u128, 0x40C00000_40A00000_00000000_00000000), qreg.read(&cpu.fp.bank, 0));
    try std.testing.expect(!ra8.chip.core.cpu.mve.vpt.inBlock(cpu.fp.vpr));
}

test "the table routes the by-scalar float encodings here" {
    for ([_][2]u16{ .{ 0xEE32, 0x0F42 }, .{ 0xEE32, 0x1F42 }, .{ 0xEE33, 0x0E62 }, .{ 0xEE33, 0x0E42 }, .{ 0xEE33, 0x1E42 }, .{ 0xFE32, 0x0F42 }, .{ 0xFE33, 0x1E42 } }) |e| {
        const hit = decode.decode(wide(e[0], e[1])) orelse return error.NotClaimed;
        try std.testing.expectEqualStrings("mve_float_scalar", hit.group);
    }
}

test "the integer by-scalar forms still route to their group" {
    for ([_][2]u16{ .{ 0xEE23, 0x0F42 }, .{ 0xEE22, 0x0F42 }, .{ 0xEE23, 0x0E42 } }) |e| {
        const hit = decode.decode(wide(e[0], e[1])) orelse return error.NotClaimed;
        try std.testing.expect(!std.mem.eql(u8, "mve_float_scalar", hit.group));
    }
}

test "unclaimed: SP or PC as Rm, D or N set, other tails" {
    try std.testing.expect(mve_float_scalar.group.decode(wide(0xEE32, 0x0F4D)) == null);
    try std.testing.expect(mve_float_scalar.group.decode(wide(0xEE32, 0x0F4F)) == null);
    try std.testing.expect(mve_float_scalar.group.decode(wide(0xEE72, 0x0F42)) == null);
    try std.testing.expect(mve_float_scalar.group.decode(wide(0xEE32, 0x0FC2)) == null);
    try std.testing.expect(mve_float_scalar.group.decode(wide(0xEE32, 0x0E62)) == null);
    try std.testing.expect(mve_float_scalar.group.decode(wide(0xEE33, 0x0F42)) == null);
}
