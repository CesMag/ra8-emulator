//! Covers src/chip/core/cpu/ops/cps.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const regs = ra8.chip.core.cpu.regs;
const cps = ra8.chip.core.cpu.ops.cps;

fn narrow(hw1: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = 0, .size = 2 };
}

fn run(cpu: *Cpu, hw1: u16) !void {
    const exec = cps.group.decode(narrow(hw1)) orelse return error.NotClaimed;
    try exec(cpu, narrow(hw1));
}

fn fresh() Cpu {
    return .{ .bus = undefined, .regs = .{ .xpsr = regs.xpsr_bits.thumb } };
}

test "cpsid i and cpsie i set and clear PRIMASK" {
    var cpu = fresh();
    try run(&cpu, 0xB672);
    try std.testing.expectEqual(@as(u32, 1), cpu.regs.primask);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.faultmask);
    try run(&cpu, 0xB662);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.primask);
}

test "cpsid f and cpsie f set and clear FAULTMASK" {
    var cpu = fresh();
    try run(&cpu, 0xB671);
    try std.testing.expectEqual(@as(u32, 1), cpu.regs.faultmask);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.primask);
    try run(&cpu, 0xB661);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.faultmask);
}

test "unprivileged thread mode leaves both masks alone" {
    var cpu = fresh();
    cpu.regs.control = regs.control_bits.npriv;
    try run(&cpu, 0xB673);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.primask);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.faultmask);
}

test "handler mode is privileged even with nPRIV set" {
    var cpu = fresh();
    cpu.regs.control = regs.control_bits.npriv;
    cpu.regs.xpsr |= 15;
    try run(&cpu, 0xB672);
    try std.testing.expectEqual(@as(u32, 1), cpu.regs.primask);
}

test "HardFault does not raise FAULTMASK but still sets PRIMASK" {
    var cpu = fresh();
    cpu.regs.xpsr |= cps.exceptions.hard_fault;
    try run(&cpu, 0xB673);
    try std.testing.expectEqual(@as(u32, 1), cpu.regs.primask);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.faultmask);
}

test "no I or F, or bit 3 set, is not claimed" {
    try std.testing.expect(cps.group.decode(narrow(0xB670)) == null);
    try std.testing.expect(cps.group.decode(narrow(0xB67A)) == null);
    try std.testing.expect(cps.group.decode(narrow(0xB650)) == null);
}
