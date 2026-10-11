//! Covers src/chip/core/cpu/ops/mve/vcmp/fp.zig. The encodings come from
//! LLVM's assembler for -mcpu=cortex-m85 with MVE floating point.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const mve_vcmp_fp = ra8.chip.core.cpu.ops.mve.vcmp.fp;
const qreg = ra8.chip.core.cpu.mve.qreg;
const vpt = ra8.chip.core.cpu.mve.vpt;
const decode = ra8.chip.core.cpu.decode;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = mve_vcmp_fp.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

// q1 = {1, 2, 3, NaN} and q2 = {2, 2, 2, 2} as F32, low lane first; r2 = 2.0.
fn loaded() Cpu {
    var cpu: Cpu = .{ .bus = undefined };
    qreg.write(&cpu.fp.bank, 1, 0x7FC00000_40400000_40000000_3F800000);
    qreg.write(&cpu.fp.bank, 2, 0x40000000_40000000_40000000_40000000);
    cpu.regs.set(2, 0x40000000);
    return cpu;
}

test "vcmp.f32 eq, ne, ge, lt, gt and le, q1, q2" {
    const cases = [_]struct { hw2: u16, p0: u16 }{
        .{ .hw2 = 0x0F04, .p0 = 0x00F0 }, .{ .hw2 = 0x0F84, .p0 = 0xFF0F },
        .{ .hw2 = 0x1F04, .p0 = 0x0FF0 }, .{ .hw2 = 0x1F84, .p0 = 0xF00F },
        .{ .hw2 = 0x1F05, .p0 = 0x0F00 }, .{ .hw2 = 0x1F85, .p0 = 0xF0FF },
    };
    for (cases) |c| {
        var cpu = loaded();
        try run(&cpu, 0xEE33, c.hw2);
        try std.testing.expectEqual(c.p0, cpu.fp.vpr.p0);
    }
}

test "ordered compares signal IOC on a quiet NaN, EQ does not" {
    var cpu = loaded();
    try run(&cpu, 0xEE33, 0x0F04);
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.fpscr.ioc);
    try run(&cpu, 0xEE33, 0x1F04);
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.fpscr.ioc);
}

test "by scalar: vcmp.f32 eq and gt, q1, r2, and vcmp.f16 le, q1, r12" {
    var cpu = loaded();
    try run(&cpu, 0xEE33, 0x0F42);
    try std.testing.expectEqual(@as(u16, 0x00F0), cpu.fp.vpr.p0);
    try run(&cpu, 0xEE33, 0x1F62);
    try std.testing.expectEqual(@as(u16, 0x0F00), cpu.fp.vpr.p0);
    qreg.write(&cpu.fp.bank, 1, 0x4400_4200_4000_3C00_4400_4200_4000_3C00);
    cpu.regs.set(12, 0xFFFF4000);
    try run(&cpu, 0xFE33, 0x1FEC);
    try std.testing.expectEqual(@as(u16, 0x0F0F), cpu.fp.vpr.p0);
}

test "vpt.f32 ge, q1, q2 opens a one-instruction block" {
    var cpu = loaded();
    try run(&cpu, 0xEE73, 0x1F04);
    try std.testing.expectEqual(@as(u16, 0x0FF0), cpu.fp.vpr.p0);
    try std.testing.expect(vpt.inBlock(cpu.fp.vpr));
}

test "floating VPT resumed after A0 opens its remaining mask and retires ECI" {
    var cpu = loaded();
    cpu.regs.xpsr = ra8.chip.core.cpu.it_state.put(cpu.regs.xpsr, 0x10);
    try run(&cpu, 0xEE73, 0x1F04);
    try std.testing.expectEqual(@as(u4, 0b1000), cpu.fp.vpr.mask01);
    try std.testing.expectEqual(@as(u4, 0b1000), cpu.fp.vpr.mask23);
    try std.testing.expectEqual(@as(u8, 0), ra8.chip.core.cpu.it_state.get(cpu.regs.xpsr));
}

test "the table routes the float compares here and the integer ones elsewhere" {
    for ([_][2]u16{ .{ 0xEE33, 0x0F04 }, .{ 0xFE33, 0x0F04 }, .{ 0xEE33, 0x1F62 }, .{ 0xEE73, 0xFFC2 } }) |e| {
        const hit = decode.decode(wide(e[0], e[1])) orelse return error.NotClaimed;
        try std.testing.expectEqualStrings("mve_vcmp_fp", hit.group);
    }
    const int = decode.decode(wide(0xFE23, 0x0F04)) orelse return error.NotClaimed;
    try std.testing.expectEqualStrings("mve_vcmp", int.group);
}

test "unclaimed: fc2 clear with fc0 set, M of Qm set, SP or PC as Rm" {
    try std.testing.expect(mve_vcmp_fp.group.decode(wide(0xEE33, 0x0F05)) == null);
    try std.testing.expect(mve_vcmp_fp.group.decode(wide(0xEE33, 0x0F62)) == null);
    try std.testing.expect(mve_vcmp_fp.group.decode(wide(0xEE33, 0x0F24)) == null);
    try std.testing.expect(mve_vcmp_fp.group.decode(wide(0xEE33, 0x0F4D)) == null);
    try std.testing.expect(mve_vcmp_fp.group.decode(wide(0xEE33, 0x0F4F)) == null);
}
