//! Covers src/chip/core/cpu/ops/long_mul.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const regs = ra8.chip.core.cpu.regs;
const long_mul = ra8.chip.core.cpu.ops.long_mul;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const exec = long_mul.group.decode(wide(hw1, hw2)) orelse return error.NotClaimed;
    try exec(cpu, wide(hw1, hw2));
}

fn fresh() Cpu {
    return .{ .bus = undefined, .regs = .{ .xpsr = regs.xpsr_bits.thumb } };
}

test "umull r2, r3, r2, r3 is the threadx_blink encoding and keeps the flags" {
    var cpu = fresh();
    cpu.regs.low[2] = 0xFFFF_FFFF;
    cpu.regs.low[3] = 0x0000_0010;
    try run(&cpu, 0xFBA2, 0x2303);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF0), cpu.regs.low[2]);
    try std.testing.expectEqual(@as(u32, 0x0000_000F), cpu.regs.low[3]);
    try std.testing.expectEqual(regs.xpsr_bits.thumb, cpu.regs.xpsr);
}

test "smull sign-extends both operands" {
    var cpu = fresh();
    cpu.regs.low[2] = 0xFFFF_FFFE; // -2
    cpu.regs.low[3] = 3;
    try run(&cpu, 0xFB82, 0x0103); // smull r0, r1, r2, r3
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFA), cpu.regs.low[0]);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), cpu.regs.low[1]);
}

test "umlal and smlal add into RdHi:RdLo with a carry across the halves" {
    var cpu = fresh();
    cpu.regs.low[0] = 0xFFFF_FFFF;
    cpu.regs.low[1] = 1;
    cpu.regs.low[2] = 1;
    cpu.regs.low[3] = 1;
    try run(&cpu, 0xFBE2, 0x0103); // umlal r0, r1, r2, r3
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.low[0]);
    try std.testing.expectEqual(@as(u32, 2), cpu.regs.low[1]);
    cpu.regs.low[2] = 0xFFFF_FFFF; // -1
    try run(&cpu, 0xFBC2, 0x0103); // smlal: 2:0 + -1
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), cpu.regs.low[0]);
    try std.testing.expectEqual(@as(u32, 1), cpu.regs.low[1]);
}

test "unpredictable fields, divides and umaal stay unclaimed" {
    try std.testing.expect(long_mul.group.decode(wide(0xFBA2, 0x2203)) == null); // RdHi == RdLo
    try std.testing.expect(long_mul.group.decode(wide(0xFBAD, 0x2303)) == null);
    try std.testing.expect(long_mul.group.decode(wide(0xFBA2, 0xD303)) == null);
    try std.testing.expect(long_mul.group.decode(wide(0xFBA2, 0x230F)) == null);
    try std.testing.expect(long_mul.group.decode(wide(0xFBB2, 0xF3F3)) == null); // UDIV
    try std.testing.expect(long_mul.group.decode(wide(0xFBE2, 0x2363)) == null); // UMAAL
}
