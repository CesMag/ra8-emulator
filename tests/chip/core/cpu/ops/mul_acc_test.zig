//! Covers src/chip/core/cpu/ops/mul_acc.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const mul_acc = ra8.chip.core.cpu.ops.mul_acc;

fn wide(hw1: u16, hw2: u16) ra8.chip.core.cpu.instr.Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const exec = mul_acc.group.decode(wide(hw1, hw2)) orelse return error.NotClaimed;
    try exec(cpu, wide(hw1, hw2));
}

test "mul r0, r1, r2 keeps the low 32 bits and leaves the flags" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[1] = 0x1_0001;
    cpu.regs.low[2] = 0x1_0003;
    const xpsr = cpu.regs.xpsr;
    try run(&cpu, 0xFB01, 0xF002);
    try std.testing.expectEqual(@as(u32, 0x0004_0003), cpu.regs.low[0]);
    try std.testing.expectEqual(xpsr, cpu.regs.xpsr);
}

test "mla r0, r1, r2, r3 adds Ra" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[1] = 6;
    cpu.regs.low[2] = 7;
    cpu.regs.low[3] = 100;
    try run(&cpu, 0xFB01, 0x3002);
    try std.testing.expectEqual(@as(u32, 142), cpu.regs.low[0]);
}

test "mls r0, r1, r2, r3 subtracts from Ra and wraps" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[1] = 6;
    cpu.regs.low[2] = 7;
    cpu.regs.low[3] = 40;
    try run(&cpu, 0xFB01, 0x3012);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFE), cpu.regs.low[0]);
}

test "unpredictable registers and other op2 values stay unclaimed" {
    try std.testing.expect(mul_acc.group.decode(wide(0xFB0D, 0xF002)) == null); // Rn = SP
    try std.testing.expect(mul_acc.group.decode(wide(0xFB01, 0xFF02)) == null); // Rd = PC
    try std.testing.expect(mul_acc.group.decode(wide(0xFB01, 0xF00F)) == null); // Rm = PC
    try std.testing.expect(mul_acc.group.decode(wide(0xFB01, 0xD002)) == null); // Ra = SP
    try std.testing.expect(mul_acc.group.decode(wide(0xFB01, 0xF012)) == null); // MLS Ra = PC
    try std.testing.expect(mul_acc.group.decode(wide(0xFB01, 0x3022)) == null); // op2 0010
    try std.testing.expect(mul_acc.group.decode(wide(0xFB11, 0x3002)) == null); // SMLA<x><y>
}
