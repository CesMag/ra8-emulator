//! Covers src/chip/core/cpu/ops/fp/move.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const fp_move = ra8.chip.core.cpu.ops.fp.move;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = fp_move.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

fn fresh() Cpu {
    return .{ .bus = undefined };
}

test "vmov s1, r2 and vmov r3, s4" {
    var cpu = fresh();
    cpu.regs.set(2, 0x7F80_0001);
    try run(&cpu, 0xEE00, 0x2A90);
    try std.testing.expectEqual(@as(u32, 0x7F80_0001), cpu.fp.bank.readS(1));
    cpu.fp.bank.writeS(4, 0xDEAD_BEEF);
    try run(&cpu, 0xEE12, 0x3A10);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), cpu.regs.get(3));
}

test "vmov s2, s3, r0, r1 and vmov r4, r5, s30, s31" {
    var cpu = fresh();
    cpu.regs.set(0, 0x1111_1111);
    cpu.regs.set(1, 0x2222_2222);
    try run(&cpu, 0xEC41, 0x0A11);
    try std.testing.expectEqual(@as(u32, 0x1111_1111), cpu.fp.bank.readS(2));
    try std.testing.expectEqual(@as(u32, 0x2222_2222), cpu.fp.bank.readS(3));
    cpu.fp.bank.writeS(30, 0x3333_3333);
    cpu.fp.bank.writeS(31, 0x4444_4444);
    try run(&cpu, 0xEC55, 0x4A1F);
    try std.testing.expectEqual(@as(u32, 0x3333_3333), cpu.regs.get(4));
    try std.testing.expectEqual(@as(u32, 0x4444_4444), cpu.regs.get(5));
}

test "vmov d3, r6, r7 puts r6 low; vmov r0, r1, d2 reads low then high" {
    var cpu = fresh();
    cpu.regs.set(6, 0x5566_7788);
    cpu.regs.set(7, 0x1122_3344);
    try run(&cpu, 0xEC47, 0x6B13);
    try std.testing.expectEqual(@as(u64, 0x1122_3344_5566_7788), cpu.fp.bank.readD(3));
    cpu.fp.bank.writeD(2, 0xAAAA_BBBB_CCCC_DDDD);
    try run(&cpu, 0xEC51, 0x0B12);
    try std.testing.expectEqual(@as(u32, 0xCCCC_DDDD), cpu.regs.get(0));
    try std.testing.expectEqual(@as(u32, 0xAAAA_BBBB), cpu.regs.get(1));
}

test "fields" {
    try std.testing.expectEqual(fp_move.Fields{ .rt = 2, .rt2 = 0, .fp = 1, .to_core = false }, fp_move.single(wide(0xEE00, 0x2A90)));
    try std.testing.expectEqual(fp_move.Fields{ .rt = 6, .rt2 = 7, .fp = 3, .to_core = false }, fp_move.pair(wide(0xEC47, 0x6B13)));
}

test "unclaimed: SP or PC, SBZ bits, S31 pair, D16+, equal destinations, half-precision SP" {
    try std.testing.expect(fp_move.group.decode(wide(0xEE00, 0xDA90)) == null);
    try std.testing.expect(fp_move.group.decode(wide(0xEE10, 0xFA10)) == null);
    try std.testing.expect(fp_move.group.decode(wide(0xEE00, 0x2AB0)) == null);
    try std.testing.expect(fp_move.group.decode(wide(0xEC41, 0x0A3F)) == null);
    try std.testing.expect(fp_move.group.decode(wide(0xEC47, 0x6B33)) == null);
    try std.testing.expect(fp_move.group.decode(wide(0xEC51, 0x1B12)) == null);
    try std.testing.expect(fp_move.group.decode(wide(0xEC4F, 0x0A11)) == null);
    try std.testing.expect(fp_move.group.decode(wide(0xEE00, 0xD990)) == null);
    try std.testing.expect(fp_move.group.decode(wide(0xEE00, 0x2B90)) == null);
    try std.testing.expect(fp_move.group.decode(wide(0xEE30, 0x0A81)) == null);
}

test "vmov.f16 s1, r2 and vmov.f16 r3, s1 move only the low halfword" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.set(2, 0xDEAD_3C00);
    cpu.fp.bank.writeS(1, 0xFFFF_FFFF);
    const to_fp = wide(0xEE00, 0x2990);
    try (fp_move.group.decode(to_fp) orelse return error.NotClaimed)(&cpu, to_fp);
    try std.testing.expectEqual(@as(u32, 0x3C00), cpu.fp.bank.readS(1));
    cpu.fp.bank.writeS(1, 0xABCD_4000);
    cpu.regs.set(3, 0xFFFF_FFFF);
    const to_core = wide(0xEE10, 0x3990);
    try (fp_move.group.decode(to_core) orelse return error.NotClaimed)(&cpu, to_core);
    try std.testing.expectEqual(@as(u32, 0x4000), cpu.regs.get(3));
}
