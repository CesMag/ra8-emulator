//! Covers src/chip/core/cpu/ops/fp/directed.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const fp_directed = ra8.chip.core.cpu.ops.fp.directed;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = fp_directed.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

fn fresh() Cpu {
    return .{ .bus = undefined };
}

test "vseleq.f32 s0, s1, s2 follows the APSR Z flag" {
    var cpu = fresh();
    cpu.fp.bank.writeS(1, 0x1111_1111);
    cpu.fp.bank.writeS(2, 0x2222_2222);
    cpu.regs.xpsr = 0x4000_0000;
    try run(&cpu, 0xFE00, 0x0A81);
    try std.testing.expectEqual(@as(u32, 0x1111_1111), cpu.fp.bank.readS(0));
    cpu.regs.xpsr = 0;
    try run(&cpu, 0xFE00, 0x0A81);
    try std.testing.expectEqual(@as(u32, 0x2222_2222), cpu.fp.bank.readS(0));
}

test "vselgt.f64 d0, d1, d2 ignores FPSCR's flags" {
    var cpu = fresh();
    cpu.fp.bank.writeD(1, 0x1111);
    cpu.fp.bank.writeD(2, 0x2222);
    cpu.fp.fpscr.z = 1;
    try run(&cpu, 0xFE31, 0x0B02);
    try std.testing.expectEqual(@as(u64, 0x1111), cpu.fp.bank.readD(0));
}

test "vmaxnm.f32 prefers the number over a quiet NaN; vminnm.f64 picks the lower" {
    var cpu = fresh();
    cpu.fp.bank.writeS(1, 0x7FC0_0000);
    cpu.fp.bank.writeS(2, 0x3F80_0000);
    try run(&cpu, 0xFE80, 0x0A81);
    try std.testing.expectEqual(@as(u32, 0x3F80_0000), cpu.fp.bank.readS(0));
    cpu.fp.bank.writeD(1, 0x4000_0000_0000_0000);
    cpu.fp.bank.writeD(2, 0xBFF0_0000_0000_0000);
    try run(&cpu, 0xFE81, 0x0B42);
    try std.testing.expectEqual(@as(u64, 0xBFF0_0000_0000_0000), cpu.fp.bank.readD(0));
}

test "vrinta and vrintn on 2.5, vrintp and vrintm on 1.1 and -1.1" {
    var cpu = fresh();
    cpu.fp.bank.writeS(1, 0x4020_0000);
    try run(&cpu, 0xFEB8, 0x0A60);
    try std.testing.expectEqual(@as(u32, 0x4040_0000), cpu.fp.bank.readS(0));
    try run(&cpu, 0xFEB9, 0x0A60);
    try std.testing.expectEqual(@as(u32, 0x4000_0000), cpu.fp.bank.readS(0));
    cpu.fp.bank.writeD(1, 0x3FF1_9999_9999_999A);
    try run(&cpu, 0xFEBA, 0x0B41);
    try std.testing.expectEqual(@as(u64, 0x4000_0000_0000_0000), cpu.fp.bank.readD(0));
    cpu.fp.bank.writeD(1, 0xBFF1_9999_9999_999A);
    try run(&cpu, 0xFEBB, 0x0B41);
    try std.testing.expectEqual(@as(u64, 0xC000_0000_0000_0000), cpu.fp.bank.readD(0));
}

test "vcvta.s32.f32 rounds ties away; vcvtm.u32.f64 rounds down" {
    var cpu = fresh();
    cpu.fp.bank.writeS(1, 0xC020_0000);
    try run(&cpu, 0xFEBC, 0x0AE0);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFD), cpu.fp.bank.readS(0));
    cpu.fp.bank.writeD(1, 0x4005_9999_9999_999A);
    try run(&cpu, 0xFEBF, 0x0B41);
    try std.testing.expectEqual(@as(u32, 2), cpu.fp.bank.readS(0));
}

test "vrintz and vrintr on -2.7, vrintx raises IXC" {
    var cpu = fresh();
    cpu.fp.bank.writeS(1, 0xC02C_CCCD);
    try run(&cpu, 0xEEB6, 0x0AE0);
    try std.testing.expectEqual(@as(u32, 0xC000_0000), cpu.fp.bank.readS(0));
    try run(&cpu, 0xEEB6, 0x0A60);
    try std.testing.expectEqual(@as(u32, 0xC040_0000), cpu.fp.bank.readS(0));
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.fpscr.ixc);
    cpu.fp.bank.writeS(1, 0x4020_0000);
    try run(&cpu, 0xEEB7, 0x0A60);
    try std.testing.expectEqual(@as(u32, 0x4000_0000), cpu.fp.bank.readS(0));
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.fpscr.ixc);
}

test "the rm field" {
    try std.testing.expectEqual(ra8.chip.core.cpu.fpu.rounding.Rounding.ties_away, fp_directed.roundingOf(0));
    try std.testing.expectEqual(ra8.chip.core.cpu.fpu.rounding.Rounding.minus_inf, fp_directed.roundingOf(3));
}

test "unclaimed: VSEL with o set, VRINTA with N set, D16+, VCVT.F64.F32" {
    try std.testing.expect(fp_directed.group.decode(wide(0xFE00, 0x0AC1)) == null);
    try std.testing.expect(fp_directed.group.decode(wide(0xFEB8, 0x0AE0)) == null);
    try std.testing.expect(fp_directed.group.decode(wide(0xFE40, 0x0B00)) == null);
    try std.testing.expect(fp_directed.group.decode(wide(0xFE80, 0x0BA0)) == null);
    try std.testing.expect(fp_directed.group.decode(wide(0xEEB7, 0x0AE0)) == null);
    try std.testing.expect(fp_directed.group.decode(wide(0xFEB8, 0x09E0)) == null);
    try std.testing.expect(fp_directed.group.decode(wide(0xFEBC, 0x0BE1)) == null);
}

test "vseleq.f16 s0, s1, s2 takes the low half and zeroes the top" {
    var cpu = fresh();
    cpu.fp.bank.writeS(1, 0xFFFF_3C00);
    cpu.fp.bank.writeS(2, 0xFFFF_4000);
    cpu.regs.xpsr = 0x4000_0000;
    try run(&cpu, 0xFE00, 0x0981);
    try std.testing.expectEqual(@as(u32, 0x3C00), cpu.fp.bank.readS(0));
    cpu.regs.xpsr = 0;
    try run(&cpu, 0xFE00, 0x0981);
    try std.testing.expectEqual(@as(u32, 0x4000), cpu.fp.bank.readS(0));
}

test "vmaxnm.f16 prefers the number over a quiet NaN; vminnm.f16 picks the lower" {
    var cpu = fresh();
    cpu.fp.bank.writeS(1, 0x7E00);
    cpu.fp.bank.writeS(2, 0x3C00);
    try run(&cpu, 0xFE80, 0x0981);
    try std.testing.expectEqual(@as(u32, 0x3C00), cpu.fp.bank.readS(0));
    cpu.fp.bank.writeS(1, 0x4000);
    cpu.fp.bank.writeS(2, 0xBC00);
    try run(&cpu, 0xFE80, 0x09C1);
    try std.testing.expectEqual(@as(u32, 0xBC00), cpu.fp.bank.readS(0));
}

test "vrinta.f16 and vrintn.f16 on 2.5" {
    var cpu = fresh();
    cpu.fp.bank.writeS(1, 0x4100);
    try run(&cpu, 0xFEB8, 0x0960);
    try std.testing.expectEqual(@as(u32, 0x4200), cpu.fp.bank.readS(0));
    try run(&cpu, 0xFEB9, 0x0960);
    try std.testing.expectEqual(@as(u32, 0x4000), cpu.fp.bank.readS(0));
}

test "vcvta.s32.f16 writes the whole word" {
    var cpu = fresh();
    cpu.fp.bank.writeS(1, 0xC100);
    try run(&cpu, 0xFEBC, 0x09E0);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFD), cpu.fp.bank.readS(0));
}

test "vrintz.f16 on -2.7, vrintx.f16 on 2.5 raises IXC" {
    var cpu = fresh();
    cpu.fp.bank.writeS(1, 0xC166);
    try run(&cpu, 0xEEB6, 0x09E0);
    try std.testing.expectEqual(@as(u32, 0xC000), cpu.fp.bank.readS(0));
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.fpscr.ixc);
    cpu.fp.bank.writeS(1, 0x4100);
    try run(&cpu, 0xEEB7, 0x0960);
    try std.testing.expectEqual(@as(u32, 0x4000), cpu.fp.bank.readS(0));
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.fpscr.ixc);
}
