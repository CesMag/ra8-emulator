//! Covers src/chip/core/cpu/ops/add/sub/wide.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const regs = ra8.chip.core.cpu.regs;
const add_sub_wide = ra8.chip.core.cpu.ops.add.sub.wide;

fn wide(address: u32, hw1: u16, hw2: u16) Instr {
    return .{ .address = address, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, instr: Instr) !void {
    const exec = add_sub_wide.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

fn fresh() Cpu {
    return .{ .bus = undefined, .regs = .{ .xpsr = regs.xpsr_bits.thumb } };
}

test "addw r3, r3, #575 is the threadx_blink encoding and keeps the flags" {
    var cpu = fresh();
    cpu.regs.low[3] = 0x1000;
    try run(&cpu, wide(0, 0xF203, 0x233F));
    try std.testing.expectEqual(@as(u32, 0x1000 + 0x23F), cpu.regs.low[3]);
    try std.testing.expectEqual(regs.xpsr_bits.thumb, cpu.regs.xpsr);
}

test "subw takes i into bit 11 and wraps" {
    var cpu = fresh();
    cpu.regs.low[1] = 0x10;
    try run(&cpu, wide(0, 0xF6A1, 0x0000)); // subw r0, r1, #0x800
    try std.testing.expectEqual(@as(u32, 0x10) -% 0x800, cpu.regs.low[0]);
}

test "adr adds to and subtracts from the word-aligned PC" {
    var cpu = fresh();
    try run(&cpu, wide(0x0200_1002, 0xF20F, 0x0210)); // adr.w r2, #+0x10
    try std.testing.expectEqual(@as(u32, 0x0200_1004 + 0x10), cpu.regs.low[2]);
    try run(&cpu, wide(0x0200_1002, 0xF2AF, 0x0210)); // adr.w r2, #-0x10
    try std.testing.expectEqual(@as(u32, 0x0200_1004 - 0x10), cpu.regs.low[2]);
}

test "addw sp, sp is claimed; rd of sp from another rn and rd of pc are not" {
    var cpu = fresh();
    cpu.regs.msp = 0x2000_0100;
    try run(&cpu, wide(0, 0xF20D, 0x0D08)); // addw sp, sp, #8
    try std.testing.expectEqual(@as(u32, 0x2000_0108), cpu.regs.sp());
    try std.testing.expect(add_sub_wide.group.decode(wide(0, 0xF203, 0x0D08)) == null);
    try std.testing.expect(add_sub_wide.group.decode(wide(0, 0xF203, 0x0F08)) == null);
}

test "movw, movt and hw2 bit 15 stay out" {
    try std.testing.expect(add_sub_wide.group.decode(wide(0, 0xF240, 0x0000)) == null);
    try std.testing.expect(add_sub_wide.group.decode(wide(0, 0xF2C0, 0x0000)) == null);
    try std.testing.expect(add_sub_wide.group.decode(wide(0, 0xF203, 0x833F)) == null);
}
