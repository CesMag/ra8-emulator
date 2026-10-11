//! Covers src/chip/core/cpu/ops/imm/logic.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const regs = ra8.chip.core.cpu.regs;
const bits = ra8.chip.core.cpu.flags.bits;
const imm_logic = ra8.chip.core.cpu.ops.imm.logic;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = imm_logic.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

fn fresh(nzcv: u32) Cpu {
    return .{ .bus = undefined, .regs = .{ .xpsr = regs.xpsr_bits.thumb | nzcv } };
}

test "mov.w r2, #0xa500 writes Rd and leaves the flags" {
    var cpu = fresh(bits.c | bits.z);
    try run(&cpu, 0xF44F, 0x4225);
    try std.testing.expectEqual(@as(u32, 0xA500), cpu.regs.get(2));
    try std.testing.expectEqual(bits.c | bits.z, cpu.regs.xpsr & 0xF000_0000);
}

test "movs.w r3, #0x80000000 sets N and the rotation's carry" {
    var cpu = fresh(bits.z | bits.v);
    try run(&cpu, 0xF05F, 0x4300);
    try std.testing.expectEqual(@as(u32, 0x8000_0000), cpu.regs.get(3));
    try std.testing.expectEqual(bits.n | bits.c | bits.v, cpu.regs.xpsr & 0xF000_0000);
}

test "mvn r0, #0x01010101" {
    var cpu = fresh(0);
    try run(&cpu, 0xF06F, 0x3001);
    try std.testing.expectEqual(@as(u32, 0xFEFE_FEFE), cpu.regs.get(0));
}

test "and, bic, orr, orn and eor against r1" {
    var cpu = fresh(0);
    cpu.regs.set(1, 0x0000_0FF0);
    try run(&cpu, 0xF001, 0x00FF);
    try std.testing.expectEqual(@as(u32, 0xF0), cpu.regs.get(0));
    try run(&cpu, 0xF021, 0x00FF);
    try std.testing.expectEqual(@as(u32, 0xF00), cpu.regs.get(0));
    try run(&cpu, 0xF041, 0x000F);
    try std.testing.expectEqual(@as(u32, 0xFFF), cpu.regs.get(0));
    try run(&cpu, 0xF061, 0x00FF);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF0), cpu.regs.get(0));
    try run(&cpu, 0xF081, 0x00FF);
    try std.testing.expectEqual(@as(u32, 0xF0F), cpu.regs.get(0));
}

test "tst r1, #0xff only sets the flags" {
    var cpu = fresh(0);
    cpu.regs.set(1, 0x100);
    try run(&cpu, 0xF011, 0x0FFF);
    try std.testing.expectEqual(bits.z, cpu.regs.xpsr & 0xF000_0000);
    try std.testing.expectEqual(@as(u32, 0x100), cpu.regs.get(1));
}

test "unpredictable forms are left unclaimed" {
    try std.testing.expect(imm_logic.group.decode(wide(0xF04F, 0x0D00)) == null);
    try std.testing.expect(imm_logic.group.decode(wide(0xF04F, 0x1000)) == null);
    try std.testing.expect(imm_logic.group.decode(wide(0xF001, 0x0F01)) == null);
    try std.testing.expect(imm_logic.group.decode(wide(0xF00D, 0x0001)) == null);
    try std.testing.expect(imm_logic.group.decode(wide(0xF101, 0x0001)) == null);
}
