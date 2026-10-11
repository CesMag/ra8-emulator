//! Covers src/chip/core/cpu/ops/mve/float/float.zig. The encodings come from LLVM's
//! assembler for -mcpu=cortex-m85 with MVE floating point.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const mve_float = ra8.chip.core.cpu.ops.mve.float;
const qreg = ra8.chip.core.cpu.mve.qreg;
const decode = ra8.chip.core.cpu.decode;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = mve_float.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

// q1 = {1, 2, 3, 4} and q2 = {2, 2, 2, 2} as F32, low lane first.
fn loaded() Cpu {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 1, 0x40800000_40400000_40000000_3F800000);
    qreg.write(&cpu.fp.bank, 2, 0x40000000_40000000_40000000_40000000);
    return cpu;
}

test "vadd, vsub, vmul and vabd .f32 q0, q1, q2" {
    var cpu = loaded();
    try run(&cpu, 0xEF02, 0x0D44);
    try std.testing.expectEqual(@as(u128, 0x40C00000_40A00000_40800000_40400000), qreg.read(&cpu.fp.bank, 0));
    try run(&cpu, 0xEF22, 0x0D44);
    try std.testing.expectEqual(@as(u128, 0x40000000_3F800000_00000000_BF800000), qreg.read(&cpu.fp.bank, 0));
    try run(&cpu, 0xFF02, 0x0D54);
    try std.testing.expectEqual(@as(u128, 0x41000000_40C00000_40800000_40000000), qreg.read(&cpu.fp.bank, 0));
    try run(&cpu, 0xFF22, 0x0D44);
    try std.testing.expectEqual(@as(u128, 0x40000000_3F800000_00000000_3F800000), qreg.read(&cpu.fp.bank, 0));
}

test "vmul.f16 q7, q1, q2 works on half lanes" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 1, 0x4400_4200_4000_3C00_4400_4200_4000_3C00);
    qreg.write(&cpu.fp.bank, 2, 0x4000_4000_4000_4000_4000_4000_4000_4000);
    try run(&cpu, 0xFF12, 0xED54);
    try std.testing.expectEqual(@as(u128, 0x4800_4600_4400_4000_4800_4600_4400_4000), qreg.read(&cpu.fp.bank, 7));
}

test "an invalid operation raises IOC in FPSCR" {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 1, 0x7F800000);
    qreg.write(&cpu.fp.bank, 2, 0x7F800000);
    try run(&cpu, 0xEF22, 0x0D44);
    try std.testing.expectEqual(@as(u32, 0x7FC00000), @as(u32, @truncate(qreg.read(&cpu.fp.bank, 0))));
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.fpscr.ioc);
}

test "inside vpst only the P0 lanes are written" {
    var cpu = loaded();
    cpu.fp.vpr = ra8.chip.core.cpu.mve.vpt.open(.{ .p0 = 0x00FF }, 0b1000);
    try run(&cpu, 0xEF02, 0x0D44);
    try std.testing.expectEqual(@as(u128, 0x40800000_40400000), qreg.read(&cpu.fp.bank, 0));
    try std.testing.expect(!ra8.chip.core.cpu.mve.vpt.inBlock(cpu.fp.vpr));
}

test "the table routes the T1 encodings here" {
    for ([_][2]u16{ .{ 0xEF02, 0x0D44 }, .{ 0xEF22, 0x0D44 }, .{ 0xFF02, 0x0D54 }, .{ 0xFF22, 0x0D44 }, .{ 0xEF12, 0x0D44 } }) |e| {
        const hit = decode.decode(wide(e[0], e[1])) orelse return error.NotClaimed;
        try std.testing.expectEqualStrings("mve_float", hit.group);
    }
}

test "unclaimed: D/N/M set, VMUL with op, the mul tail without U, other hw2" {
    try std.testing.expect(mve_float.group.decode(wide(0xEF42, 0x0D44)) == null);
    try std.testing.expect(mve_float.group.decode(wide(0xEF02, 0x0DC4)) == null);
    try std.testing.expect(mve_float.group.decode(wide(0xEF02, 0x0D64)) == null);
    try std.testing.expect(mve_float.group.decode(wide(0xFF22, 0x0D54)) == null);
    try std.testing.expect(mve_float.group.decode(wide(0xEF02, 0x0D54)) == null);
    try std.testing.expect(mve_float.group.decode(wide(0xEF02, 0x0D45)) == null);
}
