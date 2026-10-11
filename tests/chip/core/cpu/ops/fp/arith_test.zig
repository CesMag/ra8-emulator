//! Covers src/chip/core/cpu/ops/fp_arith.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const fp_arith = ra8.chip.core.cpu.ops.fp.arith;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = fp_arith.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

fn fresh() Cpu {
    return .{ .bus = undefined };
}

test "vadd.f32 s0, s1, s2" {
    var cpu = fresh();
    cpu.fp.bank.writeS(1, 0x3F80_0000);
    cpu.fp.bank.writeS(2, 0x4000_0000);
    try run(&cpu, 0xEE30, 0x0A81);
    try std.testing.expectEqual(@as(u32, 0x4040_0000), cpu.fp.bank.readS(0));
}

test "vsub.f64 d2, d3, d4" {
    var cpu = fresh();
    cpu.fp.bank.writeD(3, 0x4014_0000_0000_0000);
    cpu.fp.bank.writeD(4, 0x3FF0_0000_0000_0000);
    try run(&cpu, 0xEE33, 0x2B44);
    try std.testing.expectEqual(@as(u64, 0x4010_0000_0000_0000), cpu.fp.bank.readD(2));
}

test "vmul.f32 s4, s5, s6 and vnmul.f32 s0, s1, s2" {
    var cpu = fresh();
    cpu.fp.bank.writeS(5, 0x4040_0000);
    cpu.fp.bank.writeS(6, 0x4000_0000);
    try run(&cpu, 0xEE22, 0x2A83);
    try std.testing.expectEqual(@as(u32, 0x40C0_0000), cpu.fp.bank.readS(4));
    cpu.fp.bank.writeS(1, 0x4040_0000);
    cpu.fp.bank.writeS(2, 0x4000_0000);
    try run(&cpu, 0xEE20, 0x0AC1);
    try std.testing.expectEqual(@as(u32, 0xC0C0_0000), cpu.fp.bank.readS(0));
}

test "vmla.f32 s0, s1, s2 accumulates into s0" {
    var cpu = fresh();
    cpu.fp.bank.writeS(0, 0x3F80_0000);
    cpu.fp.bank.writeS(1, 0x4000_0000);
    cpu.fp.bank.writeS(2, 0x4040_0000);
    try run(&cpu, 0xEE00, 0x0A81);
    try std.testing.expectEqual(@as(u32, 0x40E0_0000), cpu.fp.bank.readS(0));
}

test "vfma.f64 d1, d2, d3" {
    var cpu = fresh();
    cpu.fp.bank.writeD(1, 0x3FF0_0000_0000_0000);
    cpu.fp.bank.writeD(2, 0x4000_0000_0000_0000);
    cpu.fp.bank.writeD(3, 0x4008_0000_0000_0000);
    try run(&cpu, 0xEEA2, 0x1B03);
    try std.testing.expectEqual(@as(u64, 0x401C_0000_0000_0000), cpu.fp.bank.readD(1));
}

test "vdiv.f64 d0, d1, d2 by zero sets DZC in the core's FPSCR" {
    var cpu = fresh();
    cpu.fp.bank.writeD(1, 0x3FF0_0000_0000_0000);
    try run(&cpu, 0xEE81, 0x0B02);
    try std.testing.expectEqual(@as(u64, 0x7FF0_0000_0000_0000), cpu.fp.bank.readD(0));
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.fpscr.dzc);
}

test "the operation table" {
    try std.testing.expectEqual(fp_arith.Kind.nmla, fp_arith.kindOf(wide(0xEE10, 0x0A40)).?);
    try std.testing.expectEqual(fp_arith.Kind.nmls, fp_arith.kindOf(wide(0xEE10, 0x0A00)).?);
    try std.testing.expectEqual(fp_arith.Kind.fnma, fp_arith.kindOf(wide(0xEE90, 0x0A40)).?);
    try std.testing.expectEqual(fp_arith.Kind.fms, fp_arith.kindOf(wide(0xEEA0, 0x0A40)).?);
}

test "single registers are Vx:X and doubles X:Vx" {
    const f = fp_arith.fields(wide(0xEE70 | 0x5, 0x3AA9), false);
    try std.testing.expectEqual(fp_arith.Fields{ .d = 7, .n = 11, .m = 19 }, f);
}

test "unclaimed: D16+, VDIV with op set, the VMOV/VCVT space, other coprocessors, 16-bit" {
    try std.testing.expect(fp_arith.group.decode(wide(0xEE70, 0x0B00)) == null);
    try std.testing.expect(fp_arith.group.decode(wide(0xEE30, 0x0BA0)) == null);
    try std.testing.expect(fp_arith.group.decode(wide(0xEE80, 0x0A40)) == null);
    try std.testing.expect(fp_arith.group.decode(wide(0xEEB0, 0x0A40)) == null);
    try std.testing.expect(fp_arith.group.decode(wide(0xEE30, 0x0881)) == null);
    try std.testing.expect(fp_arith.group.decode(wide(0xEE30, 0x0A91)) == null);
    try std.testing.expect(fp_arith.group.decode(.{ .address = 0, .hw1 = 0xEE30, .hw2 = 0, .size = 2 }) == null);
}

test "vadd.f16 s0, s1, s2 reads the low halves and zeroes the top" {
    var cpu = fresh();
    cpu.fp.bank.writeS(0, 0xFFFF_FFFF);
    cpu.fp.bank.writeS(1, 0xABCD_3C00);
    cpu.fp.bank.writeS(2, 0x1234_4000);
    try run(&cpu, 0xEE30, 0x0981);
    try std.testing.expectEqual(@as(u32, 0x0000_4200), cpu.fp.bank.readS(0));
}

test "vmul.f16 s4, s5, s6 overflows to infinity with OFC and IXC" {
    var cpu = fresh();
    cpu.fp.bank.writeS(5, 0x7BFF);
    cpu.fp.bank.writeS(6, 0x4000);
    try run(&cpu, 0xEE22, 0x2983);
    try std.testing.expectEqual(@as(u32, 0x7C00), cpu.fp.bank.readS(4));
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.fpscr.ofc);
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.fpscr.ixc);
}

test "f16 denormals follow FZ16, not FZ" {
    var cpu = fresh();
    cpu.fp.bank.writeS(1, 0x0001);
    cpu.fp.bank.writeS(2, 0x0001);
    cpu.fp.fpscr.fz = 1;
    try run(&cpu, 0xEE30, 0x0981);
    try std.testing.expectEqual(@as(u32, 0x0002), cpu.fp.bank.readS(0));
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.fpscr.idc);
    cpu.fp.fpscr.fz16 = 1;
    try run(&cpu, 0xEE30, 0x0981);
    try std.testing.expectEqual(@as(u32, 0), cpu.fp.bank.readS(0));
    // FPUnpack flushes a half denormal under FZ16 without raising IDC.
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.fpscr.idc);
}

test "f16 leaves the half-precision VMOV (hw2 bit 4 set) unclaimed" {
    try std.testing.expect(fp_arith.group.decode(wide(0xEE00, 0x2990)) == null);
}
