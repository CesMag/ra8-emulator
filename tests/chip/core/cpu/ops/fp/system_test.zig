//! Covers src/chip/core/cpu/ops/fp_system.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const fp_system = ra8.chip.core.cpu.ops.fp.system;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = fp_system.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

fn fresh() Cpu {
    return .{ .bus = undefined };
}

fn nzcv(cpu: *const Cpu) u4 {
    return @intCast(cpu.fp.fpscr.bits() >> 28);
}

test "vcmp.f32 s0, s1: 1.0 < 2.0 sets N" {
    var cpu = fresh();
    cpu.fp.bank.writeS(0, 0x3F80_0000);
    cpu.fp.bank.writeS(1, 0x4000_0000);
    try run(&cpu, 0xEEB4, 0x0A60);
    try std.testing.expectEqual(@as(u4, 0b1000), nzcv(&cpu));
}

test "vcmp on a quiet NaN is unordered and quiet; vcmpe signals IOC" {
    var cpu = fresh();
    cpu.fp.bank.writeD(1, 0x7FF8_0000_0000_0000);
    try run(&cpu, 0xEEB4, 0x0B41);
    try std.testing.expectEqual(@as(u4, 0b0011), nzcv(&cpu));
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.fpscr.ioc);
    try run(&cpu, 0xEEB4, 0x0BC1);
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.fpscr.ioc);
}

test "vcmp.f32 s2, #0.0 treats -0.0 as equal; positive is greater" {
    var cpu = fresh();
    cpu.fp.bank.writeS(2, 0x8000_0000);
    try run(&cpu, 0xEEB5, 0x1A40);
    try std.testing.expectEqual(@as(u4, 0b0110), nzcv(&cpu));
    cpu.fp.bank.writeS(2, 0x3F80_0000);
    try run(&cpu, 0xEEB5, 0x1A40);
    try std.testing.expectEqual(@as(u4, 0b0010), nzcv(&cpu));
}

test "vmrs APSR_nzcv, FPSCR copies only the flags" {
    var cpu = fresh();
    cpu.regs.xpsr = 0x0100_0000;
    fp_system.setNzcv(&cpu.fp.fpscr, 0b1010);
    cpu.fp.fpscr.ioc = 1;
    try run(&cpu, 0xEEF1, 0xFA10);
    try std.testing.expectEqual(@as(u32, 0xA100_0000), cpu.regs.xpsr);
}

test "vmrs r3, FPSCR and vmsr FPSCR, r2 masks reserved bits" {
    var cpu = fresh();
    cpu.regs.set(2, 0xFFFF_FFFF);
    try run(&cpu, 0xEEE1, 0x2A10);
    try std.testing.expectEqual(@as(u32, 0xFFCF_009F), cpu.fp.fpscr.bits());
    try run(&cpu, 0xEEF1, 0x3A10);
    try std.testing.expectEqual(@as(u32, 0xFFCF_009F), cpu.regs.get(3));
}

test "vmsr VPR, r4 clears the reserved byte and vmrs r5, VPR reads it back" {
    var cpu = fresh();
    cpu.regs.set(4, 0xFF34_ABCD);
    try run(&cpu, 0xEEEC, 0x4A10);
    try std.testing.expectEqual(@as(u16, 0xABCD), cpu.fp.vpr.p0);
    try std.testing.expectEqual(@as(u4, 0x4), cpu.fp.vpr.mask01);
    try std.testing.expectEqual(@as(u4, 0x3), cpu.fp.vpr.mask23);
    try run(&cpu, 0xEEFC, 0x5A10);
    try std.testing.expectEqual(@as(u32, 0x0034_ABCD), cpu.regs.get(5));
}

test "vmsr P0, r1 moves only P0 and vmrs r2, P0 zero-extends it" {
    var cpu = fresh();
    cpu.fp.vpr.mask01 = 0x8;
    cpu.regs.set(1, 0xFFFF_00F0);
    try run(&cpu, 0xEEED, 0x1A10);
    try std.testing.expectEqual(@as(u16, 0x00F0), cpu.fp.vpr.p0);
    try std.testing.expectEqual(@as(u4, 0x8), cpu.fp.vpr.mask01);
    try run(&cpu, 0xEEFD, 0x2A10);
    try std.testing.expectEqual(@as(u32, 0x00F0), cpu.regs.get(2));
}

test "FPSCR_nzcvqc transfers only condition and saturation flags" {
    var cpu = fresh();
    cpu.fp.fpscr = ra8.chip.core.cpu.fpu.fpscr.Fpscr.fromBits(0xA5CF_009F);
    try run(&cpu, 0xEEF2, 0x3A10);
    try std.testing.expectEqual(@as(u32, 0xA000_0000), cpu.regs.get(3));
    cpu.regs.set(2, 0x5800_0000);
    try run(&cpu, 0xEEE2, 0x2A10);
    try std.testing.expectEqual(@as(u32, 0x5DCF_009F), cpu.fp.fpscr.bits());
}

test "FPCXT_NS saves and restores active non-secure FP context" {
    var cpu = fresh();
    cpu.regs.control = ra8.chip.core.cpu.regs.control_bits.fpca;
    cpu.fp.fpscr = ra8.chip.core.cpu.fpu.fpscr.Fpscr.fromBits(0xA5CF_009F);
    try run(&cpu, 0xEEFE, 0x4A10);
    try std.testing.expectEqual(@as(u32, 0x05CF_009F), cpu.regs.get(4));
    try std.testing.expectEqual(cpu.fp.context.defaultFpscr().bits(), cpu.fp.fpscr.bits());
    cpu.regs.set(5, 0xD123_4567);
    try run(&cpu, 0xEEEE, 0x5A10);
    try std.testing.expectEqual(ra8.chip.core.cpu.fpu.fpscr.Fpscr.fromBits(0x0123_4567).bits(), cpu.fp.fpscr.bits());
    try std.testing.expect(cpu.regs.control & ra8.chip.core.cpu.regs.control_bits.sfpa != 0);
}

test "FPCXT_NS inactive: a read returns the NS defaults and a write is a NOP" {
    var cpu = fresh();
    try run(&cpu, 0xEEFE, 0x6A10);
    try std.testing.expectEqual(cpu.fp.context.defaultFpscr().bits() & 0x0FFF_FFFF, cpu.regs.get(6));
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.control);
    const before = cpu.fp.fpscr.bits();
    cpu.regs.set(7, 0x8000_0000 | 0x0040_0000);
    try run(&cpu, 0xEEEE, 0x7A10);
    try std.testing.expectEqual(before, cpu.fp.fpscr.bits());
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.control);
}

test "FPCXT_S saves and restores the Secure FP context" {
    var cpu = fresh();
    cpu.regs.control |= ra8.chip.core.cpu.regs.control_bits.sfpa;
    cpu.fp.fpscr = ra8.chip.core.cpu.fpu.fpscr.Fpscr.fromBits(0xA5CF_009F);
    try run(&cpu, 0xEEFF, 0x8A10);
    try std.testing.expectEqual(@as(u32, 0x85CF_009F), cpu.regs.get(8));
    try std.testing.expectEqual(cpu.fp.context.defaultFpscr().bits(), cpu.fp.fpscr.bits());
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.control & ra8.chip.core.cpu.regs.control_bits.sfpa);
    cpu.regs.set(9, 0xC123_4567);
    try run(&cpu, 0xEEEF, 0x9A10);
    try std.testing.expectEqual(ra8.chip.core.cpu.fpu.fpscr.Fpscr.fromBits(0x0123_4567).bits(), cpu.fp.fpscr.bits());
    try std.testing.expect(cpu.regs.control & ra8.chip.core.cpu.regs.control_bits.sfpa != 0);
}

test "FPCXT payload accesses are undefined from Non-secure state" {
    var cpu = fresh();
    cpu.banked.current = .non_secure;
    const cases = [_]struct { hw1: u16, hw2: u16 }{
        .{ .hw1 = 0xEEFE, .hw2 = 0x0A10 },
        .{ .hw1 = 0xEEEE, .hw2 = 0x0A10 },
        .{ .hw1 = 0xEEFF, .hw2 = 0x0A10 },
        .{ .hw1 = 0xEEEF, .hw2 = 0x0A10 },
    };
    for (cases) |case| {
        const instr = wide(case.hw1, case.hw2);
        const exec = fp_system.group.decode(instr).?;
        try std.testing.expectError(error.Undefined, exec(&cpu, instr));
    }
}

test "VPR and P0 transfers leave SP and PC unclaimed" {
    try std.testing.expect(fp_system.group.decode(wide(0xEEFC, 0xDA10)) == null);
    try std.testing.expect(fp_system.group.decode(wide(0xEEED, 0xFA10)) == null);
    try std.testing.expect(fp_system.group.decode(wide(0xEEFD, 0xFA10)) == null);
}

test "unclaimed: SBZ bits, D16+, SP or PC, other system registers, arith space" {
    try std.testing.expect(fp_system.group.decode(wide(0xEEB5, 0x1A60)) == null);
    try std.testing.expect(fp_system.group.decode(wide(0xEEB5, 0x1A41)) == null);
    try std.testing.expect(fp_system.group.decode(wide(0xEEF4, 0x0B40)) == null);
    try std.testing.expect(fp_system.group.decode(wide(0xEEB4, 0x0B61)) == null);
    try std.testing.expect(fp_system.group.decode(wide(0xEEF1, 0xDA10)) == null);
    try std.testing.expect(fp_system.group.decode(wide(0xEEE1, 0xFA10)) == null);
    try std.testing.expect(fp_system.group.decode(wide(0xEEF3, 0x3A10)) == null);
    try std.testing.expect(fp_system.group.decode(wide(0xEEF1, 0x3A30)) == null);
    try std.testing.expect(fp_system.group.decode(wide(0xEE30, 0x0A81)) == null);
}

test "vcmp.f16 s0, s1 and vcmp.f16 s0, #0 compare the low halves" {
    var cpu = fresh();
    cpu.fp.bank.writeS(0, 0xFFFF_3C00);
    cpu.fp.bank.writeS(1, 0x0000_4000);
    try run(&cpu, 0xEEB4, 0x0960);
    try std.testing.expectEqual(@as(u4, 0b1000), nzcv(&cpu));
    cpu.fp.bank.writeS(0, 0x8000);
    try run(&cpu, 0xEEB5, 0x0940);
    try std.testing.expectEqual(@as(u4, 0b0110), nzcv(&cpu));
}

test "vcmpe.f16 with a quiet NaN is unordered and raises IOC" {
    var cpu = fresh();
    cpu.fp.bank.writeS(0, 0x7E00);
    try run(&cpu, 0xEEB4, 0x09E0);
    try std.testing.expectEqual(@as(u4, 0b0011), nzcv(&cpu));
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.fpscr.ioc);
}
