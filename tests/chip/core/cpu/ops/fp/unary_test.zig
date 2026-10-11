//! Covers src/chip/core/cpu/ops/fp/unary.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const Fpscr = ra8.chip.core.cpu.fpu.fpscr.Fpscr;
const fp_unary = ra8.chip.core.cpu.ops.fp.unary;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = fp_unary.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

fn fresh() Cpu {
    return .{ .bus = undefined };
}

fn fpscrBits(cpu: *const Cpu) u32 {
    return @bitCast(cpu.fp.fpscr);
}

test "vmov.f32 s0, #1.0 and vmov.f64 d1, #-2.0" {
    var cpu = fresh();
    try run(&cpu, 0xEEB7, 0x0A00);
    try std.testing.expectEqual(@as(u32, 0x3F80_0000), cpu.fp.bank.readS(0));
    try run(&cpu, 0xEEB8, 0x1B00);
    try std.testing.expectEqual(@as(u64, 0xC000_0000_0000_0000), cpu.fp.bank.readD(1));
}

test "vmov.f32 s1, s2 copies a signalling NaN untouched" {
    var cpu = fresh();
    cpu.fp.bank.writeS(2, 0x7F80_0001);
    try run(&cpu, 0xEEF0, 0x0A41);
    try std.testing.expectEqual(@as(u32, 0x7F80_0001), cpu.fp.bank.readS(1));
    try std.testing.expectEqual(@as(u32, @bitCast(Fpscr{})), fpscrBits(&cpu));
}

test "vabs.f64 d0, d1 clears the sign and raises nothing on a NaN" {
    var cpu = fresh();
    cpu.fp.bank.writeD(1, 0xFFF0_0000_0000_0001);
    try run(&cpu, 0xEEB0, 0x0BC1);
    try std.testing.expectEqual(@as(u64, 0x7FF0_0000_0000_0001), cpu.fp.bank.readD(0));
    try std.testing.expectEqual(@as(u32, @bitCast(Fpscr{})), fpscrBits(&cpu));
}

test "vneg.f32 s0, s1 flips the sign" {
    var cpu = fresh();
    cpu.fp.bank.writeS(1, 0x4000_0000);
    try run(&cpu, 0xEEB1, 0x0A60);
    try std.testing.expectEqual(@as(u32, 0xC000_0000), cpu.fp.bank.readS(0));
}

test "vsqrt.f32 s0, s1 and the default NaN with IOC on a negative" {
    var cpu = fresh();
    cpu.fp.bank.writeS(1, 0x4080_0000);
    try run(&cpu, 0xEEB1, 0x0AE0);
    try std.testing.expectEqual(@as(u32, 0x4000_0000), cpu.fp.bank.readS(0));
    cpu.fp.bank.writeS(1, 0xBF80_0000);
    try run(&cpu, 0xEEB1, 0x0AE0);
    try std.testing.expectEqual(@as(u32, 0x7FC0_0000), cpu.fp.bank.readS(0));
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.fpscr.ioc);
}

test "vsqrt.f64 d2, d3" {
    var cpu = fresh();
    cpu.fp.bank.writeD(3, 0x4022_0000_0000_0000);
    try run(&cpu, 0xEEB1, 0x2BC3);
    try std.testing.expectEqual(@as(u64, 0x4008_0000_0000_0000), cpu.fp.bank.readD(2));
}

test "fields and imm8" {
    try std.testing.expectEqual(fp_unary.Fields{ .d = 1, .m = 2 }, fp_unary.fields(wide(0xEEF0, 0x0A41), false));
    try std.testing.expectEqual(fp_unary.Fields{ .d = 16, .m = 17 }, fp_unary.fields(wide(0xEEF0, 0x0B61), true));
    try std.testing.expectEqual(@as(u8, 0x70), fp_unary.imm8(wide(0xEEB7, 0x0A00)));
}

test "unclaimed: VCMP space, SBZ bits of the immediate, D16+, bit 4, arith space, 16-bit" {
    try std.testing.expect(fp_unary.group.decode(wide(0xEEB4, 0x0A40)) == null);
    try std.testing.expect(fp_unary.group.decode(wide(0xEEB7, 0x0A20)) == null);
    try std.testing.expect(fp_unary.group.decode(wide(0xEEB7, 0x0A80)) == null);
    try std.testing.expect(fp_unary.group.decode(wide(0xEEF0, 0x0B41)) == null);
    try std.testing.expect(fp_unary.group.decode(wide(0xEEB0, 0x0B61)) == null);
    try std.testing.expect(fp_unary.group.decode(wide(0xEEB0, 0x0A50)) == null);
    try std.testing.expect(fp_unary.group.decode(wide(0xEE30, 0x0A81)) == null);
    try std.testing.expect(fp_unary.group.decode(.{ .address = 0, .hw1 = 0xEEB0, .hw2 = 0, .size = 2 }) == null);
}

test "vabs.f16, vneg.f16 and vsqrt.f16 read the low half and zero the top" {
    var cpu = fresh();
    cpu.fp.bank.writeS(1, 0xFFFF_BC00);
    try run(&cpu, 0xEEB0, 0x09E0);
    try std.testing.expectEqual(@as(u32, 0x3C00), cpu.fp.bank.readS(0));
    cpu.fp.bank.writeS(3, 0x1234_3C00);
    try run(&cpu, 0xEEB1, 0x1961);
    try std.testing.expectEqual(@as(u32, 0xBC00), cpu.fp.bank.readS(2));
    cpu.fp.bank.writeS(5, 0x4400);
    try run(&cpu, 0xEEB1, 0x29E2);
    try std.testing.expectEqual(@as(u32, 0x4000), cpu.fp.bank.readS(4));
}

test "vmov.f16 s6, #1.0 expands to 0x3C00" {
    var cpu = fresh();
    cpu.fp.bank.writeS(6, 0xFFFF_FFFF);
    try run(&cpu, 0xEEB7, 0x3900);
    try std.testing.expectEqual(@as(u32, 0x3C00), cpu.fp.bank.readS(6));
}

test "vmov (register) has no half form" {
    try std.testing.expect(fp_unary.group.decode(wide(0xEEB0, 0x0960)) == null);
}
