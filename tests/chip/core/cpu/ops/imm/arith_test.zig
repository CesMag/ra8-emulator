//! Covers src/chip/core/cpu/ops/imm_arith.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const regs = ra8.chip.core.cpu.regs;
const bits = ra8.chip.core.cpu.flags.bits;
const imm_arith = ra8.chip.core.cpu.ops.imm_arith;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = imm_arith.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

fn fresh(nzcv: u32) Cpu {
    var cpu: Cpu = .{ .bus = undefined, .regs = .{ .xpsr = regs.xpsr_bits.thumb | nzcv } };
    cpu.regs.msp = 0x2000_1000;
    return cpu;
}

test "add.w r1, r2, #0x100" {
    var cpu = fresh(0);
    cpu.regs.set(2, 5);
    try run(&cpu, 0xF502, 0x7180);
    try std.testing.expectEqual(@as(u32, 0x105), cpu.regs.get(1));
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.xpsr & 0xF000_0000);
}

test "cmp.w r0, #1 on equal values sets Z and C" {
    var cpu = fresh(bits.n);
    cpu.regs.set(0, 1);
    try run(&cpu, 0xF1B0, 0x0F01);
    try std.testing.expectEqual(bits.z | bits.c, cpu.regs.xpsr & 0xF000_0000);
    try std.testing.expectEqual(@as(u32, 1), cpu.regs.get(0));
}

test "adds.w overflows into V" {
    var cpu = fresh(0);
    cpu.regs.set(4, 0x7FFF_FFFF);
    try run(&cpu, 0xF114, 0x0401);
    try std.testing.expectEqual(@as(u32, 0x8000_0000), cpu.regs.get(4));
    try std.testing.expectEqual(bits.n | bits.v, cpu.regs.xpsr & 0xF000_0000);
}

test "adc and sbc use the carry" {
    var cpu = fresh(bits.c);
    cpu.regs.set(1, 10);
    try run(&cpu, 0xF141, 0x0001);
    try std.testing.expectEqual(@as(u32, 12), cpu.regs.get(0));
    try run(&cpu, 0xF161, 0x0001);
    try std.testing.expectEqual(@as(u32, 9), cpu.regs.get(0));
}

test "rsb r0, r1, #0 negates" {
    var cpu = fresh(0);
    cpu.regs.set(1, 5);
    try run(&cpu, 0xF1C1, 0x0000);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFB), cpu.regs.get(0));
}

test "sub.w sp, sp, #8 moves the stack pointer" {
    var cpu = fresh(0);
    try run(&cpu, 0xF1AD, 0x0D08);
    try std.testing.expectEqual(@as(u32, 0x2000_0FF8), cpu.regs.get(13));
}

test "unpredictable forms and other opcodes are left unclaimed" {
    try std.testing.expect(imm_arith.group.decode(wide(0xF10F, 0x0001)) == null);
    try std.testing.expect(imm_arith.group.decode(wide(0xF1BF, 0x0F01)) == null);
    try std.testing.expect(imm_arith.group.decode(wide(0xF141, 0x0D01)) == null);
    try std.testing.expect(imm_arith.group.decode(wide(0xF1AD, 0x0F08)) == null);
    try std.testing.expect(imm_arith.group.decode(wide(0xF04F, 0x0001)) == null);
}
