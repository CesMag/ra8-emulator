//! Covers src/chip/core/cpu/ops/misc_wide.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const misc_wide = ra8.chip.core.cpu.ops.misc_wide;

fn wide(hw1: u16, hw2: u16) ra8.chip.core.cpu.instr.Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const exec = misc_wide.group.decode(wide(hw1, hw2)) orelse return error.NotClaimed;
    try exec(cpu, wide(hw1, hw2));
}

test "rev.w, rev16.w and revsh.w r0, r1" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[1] = 0x1122_33F4;
    try run(&cpu, 0xFA91, 0xF081);
    try std.testing.expectEqual(@as(u32, 0xF433_2211), cpu.regs.low[0]);
    try run(&cpu, 0xFA91, 0xF091);
    try std.testing.expectEqual(@as(u32, 0x2211_F433), cpu.regs.low[0]);
    try run(&cpu, 0xFA91, 0xF0B1);
    try std.testing.expectEqual(@as(u32, 0xFFFF_F433), cpu.regs.low[0]);
}

test "rbit r2, r3 reverses every bit" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[3] = 0x0000_0001;
    try run(&cpu, 0xFA93, 0xF2A3);
    try std.testing.expectEqual(@as(u32, 0x8000_0000), cpu.regs.low[2]);
}

test "clz r0, r1 counts leading zeros, 32 for zero" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[1] = 0x0001_0000;
    try run(&cpu, 0xFAB1, 0xF081);
    try std.testing.expectEqual(@as(u32, 15), cpu.regs.low[0]);
    cpu.regs.low[1] = 0;
    try run(&cpu, 0xFAB1, 0xF081);
    try std.testing.expectEqual(@as(u32, 32), cpu.regs.low[0]);
}

test "mismatched Rm, sp/pc, SEL and other op2 values stay unclaimed" {
    try std.testing.expect(misc_wide.group.decode(wide(0xFA91, 0xF082)) == null); // Rm copies differ
    try std.testing.expect(misc_wide.group.decode(wide(0xFA9D, 0xF08D)) == null); // Rm = SP
    try std.testing.expect(misc_wide.group.decode(wide(0xFAB1, 0xFF81)) == null); // Rd = PC
    try std.testing.expect(misc_wide.group.decode(wide(0xFAA1, 0xF082)) == null); // SEL
    try std.testing.expect(misc_wide.group.decode(wide(0xFAB1, 0xF091)) == null); // CLZ op2 0001
}
