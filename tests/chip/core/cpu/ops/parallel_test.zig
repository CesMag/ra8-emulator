//! Covers src/chip/core/cpu/ops/parallel.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const parallel = ra8.chip.core.cpu.ops.parallel;
const xpsr_bits = ra8.chip.core.cpu.regs.xpsr_bits;

fn wide(hw1: u16, hw2: u16) ra8.chip.core.cpu.instr.Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

/// Runs r0 = op(r1, r2) and returns r0 and the GE bits.
fn run(hw1: u16, hw2: u16, n: u32, m: u32) !struct { u32, u32 } {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.xpsr |= 0x5 << xpsr_bits.ge_shift;
    cpu.regs.low[1] = n;
    cpu.regs.low[2] = m;
    const exec = parallel.group.decode(wide(hw1, hw2)) orelse return error.NotClaimed;
    try exec(&cpu, wide(hw1, hw2));
    return .{ cpu.regs.low[0], (cpu.regs.xpsr & xpsr_bits.ge) >> xpsr_bits.ge_shift };
}

fn expectRun(hw1: u16, hw2: u16, n: u32, m: u32, value: u32, ge: u32) !void {
    const got = try run(hw1, hw2, n, m);
    try std.testing.expectEqual(value, got[0]);
    try std.testing.expectEqual(ge, got[1]);
}

test "sadd16 and qadd16" {
    try expectRun(0xFA91, 0xF002, 0x7FFF_0001, 0x0001_FFFF, 0x8000_0000, 0xF);
    try expectRun(0xFA91, 0xF012, 0x7FFF_0001, 0x0001_FFFF, 0x7FFF_0000, 0x5);
}

test "uadd8 sets GE on each carry out" {
    try expectRun(0xFA81, 0xF042, 0xFF01_8000, 0x0101_8001, 0x0002_0001, 0xA);
}

test "usub16 replaces the stale GE bits" {
    try expectRun(0xFAD1, 0xF042, 0x0001_0005, 0x0002_0003, 0xFFFF_0002, 0x3);
}

test "sasx and ssax cross the halfwords" {
    try expectRun(0xFAA1, 0xF002, 0x0010_0005, 0x0003_0007, 0x0017_0002, 0xF);
    try expectRun(0xFAE1, 0xF002, 0x0010_0005, 0x0003_0007, 0x0009_0008, 0xF);
}

test "halving and unsigned saturating forms" {
    try expectRun(0xFA81, 0xF022, 0x0000_00FE, 0x0000_0004, 0x0000_0001, 0x5);
    try expectRun(0xFAD1, 0xF062, 0x0000_0001, 0x0000_0003, 0x0000_FFFF, 0x5);
    try expectRun(0xFAC1, 0xF052, 0x0000_0005, 0x0000_0007, 0x0000_0000, 0x5);
}

test "reserved rows and sp/pc stay unclaimed" {
    try std.testing.expect(parallel.group.decode(wide(0xFAB1, 0xF002)) == null); // op1 011
    try std.testing.expect(parallel.group.decode(wide(0xFAF1, 0xF002)) == null); // op1 111
    try std.testing.expect(parallel.group.decode(wide(0xFA91, 0xF032)) == null); // op2 11
    try std.testing.expect(parallel.group.decode(wide(0xFA91, 0xF082)) == null); // hw2[7]
    try std.testing.expect(parallel.group.decode(wide(0xFA9D, 0xF002)) == null); // Rn = SP
    try std.testing.expect(parallel.group.decode(wide(0xFA91, 0xFF02)) == null); // Rd = PC
}
