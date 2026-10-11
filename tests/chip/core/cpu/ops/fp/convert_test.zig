//! Covers src/chip/core/cpu/ops/fp_convert.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const fp_convert = ra8.chip.core.cpu.ops.fp.convert;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = fp_convert.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

fn fresh() Cpu {
    return .{ .bus = undefined };
}

test "vcvt.f64.f32 d0, s1 and vcvt.f32.f64 s0, d1" {
    var cpu = fresh();
    cpu.fp.bank.writeS(1, 0x3FC0_0000);
    try run(&cpu, 0xEEB7, 0x0AE0);
    try std.testing.expectEqual(@as(u64, 0x3FF8_0000_0000_0000), cpu.fp.bank.readD(0));
    cpu.fp.bank.writeD(1, 0xC004_0000_0000_0000);
    try run(&cpu, 0xEEB7, 0x0BC1);
    try std.testing.expectEqual(@as(u32, 0xC020_0000), cpu.fp.bank.readS(0));
}

test "vcvt.s32.f32 truncates; vcvtr.s32.f32 rounds to nearest" {
    var cpu = fresh();
    cpu.fp.bank.writeS(1, 0x4060_0000);
    try run(&cpu, 0xEEBD, 0x0AE0);
    try std.testing.expectEqual(@as(u32, 3), cpu.fp.bank.readS(0));
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.fpscr.ixc);
    try run(&cpu, 0xEEBD, 0x0A60);
    try std.testing.expectEqual(@as(u32, 4), cpu.fp.bank.readS(0));
}

test "vcvt.u32.f64 s0, d1 saturates a negative to 0 with IOC" {
    var cpu = fresh();
    cpu.fp.bank.writeD(1, 0xBFF0_0000_0000_0000);
    cpu.fp.bank.writeS(0, 0x1234);
    try run(&cpu, 0xEEBC, 0x0BC1);
    try std.testing.expectEqual(@as(u32, 0), cpu.fp.bank.readS(0));
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.fpscr.ioc);
}

test "vcvt.f32.s32 s0, s1 and vcvt.f64.u32 d0, s1" {
    var cpu = fresh();
    cpu.fp.bank.writeS(1, @bitCast(@as(i32, -3)));
    try run(&cpu, 0xEEB8, 0x0AE0);
    try std.testing.expectEqual(@as(u32, 0xC040_0000), cpu.fp.bank.readS(0));
    cpu.fp.bank.writeS(1, 0xFFFF_FFFF);
    try run(&cpu, 0xEEB8, 0x0B60);
    try std.testing.expectEqual(@as(u64, 0x41EF_FFFF_FFE0_0000), cpu.fp.bank.readD(0));
}

test "vcvt.s32.f32 s0, s0, #16 to fixed point" {
    var cpu = fresh();
    cpu.fp.bank.writeS(0, 0x3FC0_0000);
    try run(&cpu, 0xEEBE, 0x0AC8);
    try std.testing.expectEqual(@as(u32, 0x0001_8000), cpu.fp.bank.readS(0));
}

test "vcvt.f64.u16 d1, d1, #8 reads only the low 16 bits" {
    var cpu = fresh();
    cpu.fp.bank.writeD(1, 0xDEAD_BEEF_ABCD_0180);
    try run(&cpu, 0xEEBB, 0x1B44);
    try std.testing.expectEqual(@as(u64, 0x3FF8_0000_0000_0000), cpu.fp.bank.readD(1));
}

test "vcvt.s16.f64 d2, d2, #0 extends the result to 64 bits" {
    var cpu = fresh();
    cpu.fp.bank.writeD(2, 0xBFF0_0000_0000_0000);
    try run(&cpu, 0xEEBE, 0x2B48);
    try std.testing.expectEqual(@as(u64, 0xFFFF_FFFF_FFFF_FFFF), cpu.fp.bank.readD(2));
}

test "vcvtb.f32.f16, vcvtb.f64.f16 and vcvtt.f16.f32 keep the other lane" {
    var cpu = fresh();
    cpu.fp.bank.writeS(1, 0xABCD_3C00);
    try run(&cpu, 0xEEB2, 0x0A60);
    try std.testing.expectEqual(@as(u32, 0x3F80_0000), cpu.fp.bank.readS(0));
    cpu.fp.bank.writeS(1, 0x0000_C000);
    try run(&cpu, 0xEEB2, 0x0B60);
    try std.testing.expectEqual(@as(u64, 0xC000_0000_0000_0000), cpu.fp.bank.readD(0));
    cpu.fp.bank.writeS(0, 0x0000_1234);
    cpu.fp.bank.writeS(1, 0x4000_0000);
    try run(&cpu, 0xEEB3, 0x0AE0);
    try std.testing.expectEqual(@as(u32, 0x4000_1234), cpu.fp.bank.readS(0));
}

test "operand widths and fixed-point fields" {
    try std.testing.expectEqual(fp_convert.Widths{ .d = false, .m = true }, fp_convert.widths(.precision, true));
    try std.testing.expectEqual(fp_convert.Fixed{ .width = 32, .fbits = 16 }, fp_convert.fixedOf(wide(0xEEBE, 0x0AC8)).?);
    try std.testing.expect(fp_convert.fixedOf(wide(0xEEBA, 0x0A68)) == null);
    try std.testing.expectEqual(@as(u64, 0x0000_0000_FFFF_FFFF), fp_convert.extend(ra8.chip.core.cpu.fpu.format.double, 0xFFFF_FFFF, true));
}

test "unclaimed: opc2 0111 with o clear, imm5 too wide, D16+, VCMP and VRINT space, bit 4" {
    try std.testing.expect(fp_convert.group.decode(wide(0xEEB7, 0x0A60)) == null);
    try std.testing.expect(fp_convert.group.decode(wide(0xEEBA, 0x0A68)) == null);
    try std.testing.expect(fp_convert.group.decode(wide(0xEEF8, 0x0B60)) == null);
    try std.testing.expect(fp_convert.group.decode(wide(0xEEBD, 0x0BE1)) == null);
    try std.testing.expect(fp_convert.group.decode(wide(0xEEB4, 0x0A60)) == null);
    try std.testing.expect(fp_convert.group.decode(wide(0xEEB6, 0x0A60)) == null);
    try std.testing.expect(fp_convert.group.decode(wide(0xEEB8, 0x0A70)) == null);
}
