//! Covers src/chip/core/cpu/ops/dp_shifted.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const regs = ra8.chip.core.cpu.regs;
const flags = ra8.chip.core.cpu.flags;
const dp_shifted = ra8.chip.core.cpu.ops.dp_shifted;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = dp_shifted.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

fn fresh() Cpu {
    return .{ .bus = undefined, .regs = .{ .xpsr = regs.xpsr_bits.thumb } };
}

test "cmp.w r0, r1, lsr #24 is the blink_hal encoding and only sets flags" {
    var cpu = fresh();
    cpu.regs.low[0] = 0x0000_0001;
    cpu.regs.low[1] = 0x0100_0000;
    try run(&cpu, 0xEBB0, 0x6F11);
    try std.testing.expectEqual(@as(u32, 0x0000_0001), cpu.regs.low[0]);
    try std.testing.expect(cpu.regs.xpsr & flags.bits.z != 0);
    try std.testing.expect(cpu.regs.xpsr & flags.bits.c != 0);
}

test "add.w r2, r3, r4, lsr #4 adds the shifted register without flags" {
    var cpu = fresh();
    cpu.regs.low[3] = 10;
    cpu.regs.low[4] = 0x100;
    try run(&cpu, 0xEB03, 0x1214);
    try std.testing.expectEqual(@as(u32, 26), cpu.regs.low[2]);
    try std.testing.expectEqual(regs.xpsr_bits.thumb, cpu.regs.xpsr);
}

test "ands.w takes C from the shifter" {
    var cpu = fresh();
    cpu.regs.low[1] = 0xFFFF_FFFF;
    cpu.regs.low[2] = 0x0000_0003;
    try run(&cpu, 0xEA11, 0x0052); // ands.w r0, r1, r2, lsr #1
    try std.testing.expectEqual(@as(u32, 1), cpu.regs.low[0]);
    try std.testing.expect(cpu.regs.xpsr & flags.bits.c != 0);
}

test "mov.w with Rn of PC and mvn.w with Rn of PC" {
    var cpu = fresh();
    cpu.regs.low[5] = 0x0000_00F0;
    try run(&cpu, 0xEA4F, 0x1605); // mov.w r6, r5, lsl #4
    try std.testing.expectEqual(@as(u32, 0x0F00), cpu.regs.low[6]);
    try run(&cpu, 0xEA6F, 0x0705); // mvn.w r7, r5
    try std.testing.expectEqual(@as(u32, 0xFFFF_FF0F), cpu.regs.low[7]);
}

test "rsb.w and sbc.w use the carry chain" {
    var cpu = fresh();
    cpu.regs.low[1] = 3;
    cpu.regs.low[2] = 10;
    try run(&cpu, 0xEBC1, 0x0002); // rsb.w r0, r1, r2
    try std.testing.expectEqual(@as(u32, 7), cpu.regs.low[0]);
    try run(&cpu, 0xEB62, 0x0001); // sbc.w r0, r2, r1 with C clear
    try std.testing.expectEqual(@as(u32, 6), cpu.regs.low[0]);
}

test "rrx through orr.w with Rn of PC" {
    var cpu = fresh();
    cpu.regs.xpsr |= flags.bits.c;
    cpu.regs.low[1] = 2;
    try run(&cpu, 0xEA5F, 0x0031); // movs.w r0, r1, rrx
    try std.testing.expectEqual(@as(u32, 0x8000_0001), cpu.regs.low[0]);
    try std.testing.expect(cpu.regs.xpsr & flags.bits.c == 0);
}

test "add.w with Rn of SP is claimed, SP or PC elsewhere is not" {
    try std.testing.expect(dp_shifted.group.decode(wide(0xEB0D, 0x0001)) != null);
    try std.testing.expect(dp_shifted.group.decode(wide(0xEA01, 0x0D02)) == null);
    try std.testing.expect(dp_shifted.group.decode(wide(0xEA01, 0x000F)) == null);
    try std.testing.expect(dp_shifted.group.decode(wide(0xEAC1, 0x0002)) == null); // PKH
    try std.testing.expect(dp_shifted.group.decode(wide(0xEB01, 0x8002)) == null);
}
