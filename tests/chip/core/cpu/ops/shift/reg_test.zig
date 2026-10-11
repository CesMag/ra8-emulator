//! Covers src/chip/core/cpu/ops/shift/reg.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const regs = ra8.chip.core.cpu.regs;
const flags = ra8.chip.core.cpu.flags;
const shift_reg = ra8.chip.core.cpu.ops.shift.reg;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const exec = shift_reg.group.decode(wide(hw1, hw2)) orelse return error.NotClaimed;
    try exec(cpu, wide(hw1, hw2));
}

fn fresh() Cpu {
    return .{ .bus = undefined, .regs = .{ .xpsr = regs.xpsr_bits.thumb } };
}

test "lsl.w r3, r2, r3 is the threadx_blink encoding and keeps the flags" {
    var cpu = fresh();
    cpu.regs.low[2] = 1;
    cpu.regs.low[3] = 0x0000_0105; // only the bottom byte counts: 5
    try run(&cpu, 0xFA02, 0xF303);
    try std.testing.expectEqual(@as(u32, 32), cpu.regs.low[3]);
    try std.testing.expectEqual(regs.xpsr_bits.thumb, cpu.regs.xpsr);
}

test "lsrs.w by 32 clears the result and moves bit 31 into C" {
    var cpu = fresh();
    cpu.regs.low[1] = 0x8000_0000;
    cpu.regs.low[2] = 32;
    try run(&cpu, 0xFA31, 0xF002); // lsrs.w r0, r1, r2
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.low[0]);
    try std.testing.expect(cpu.regs.xpsr & flags.bits.z != 0);
    try std.testing.expect(cpu.regs.xpsr & flags.bits.c != 0);
}

test "asr.w and ror.w by a register" {
    var cpu = fresh();
    cpu.regs.low[1] = 0x8000_0000;
    cpu.regs.low[2] = 4;
    try run(&cpu, 0xFA41, 0xF002); // asr.w r0, r1, r2
    try std.testing.expectEqual(@as(u32, 0xF800_0000), cpu.regs.low[0]);
    cpu.regs.low[1] = 0x0000_00F1;
    try run(&cpu, 0xFA61, 0xF002); // ror.w r0, r1, r2
    try std.testing.expectEqual(@as(u32, 0x1000_000F), cpu.regs.low[0]);
}

test "movs with a zero amount keeps C" {
    var cpu = fresh();
    cpu.regs.xpsr |= flags.bits.c;
    cpu.regs.low[1] = 5;
    cpu.regs.low[2] = 0x100;
    try run(&cpu, 0xFA11, 0xF002); // lsls.w r0, r1, r2 by 0
    try std.testing.expectEqual(@as(u32, 5), cpu.regs.low[0]);
    try std.testing.expect(cpu.regs.xpsr & flags.bits.c != 0);
}

test "SP or PC fields and the extend space stay unclaimed" {
    try std.testing.expect(shift_reg.group.decode(wide(0xFA02, 0xFD03)) == null);
    try std.testing.expect(shift_reg.group.decode(wide(0xFA0D, 0xF303)) == null);
    try std.testing.expect(shift_reg.group.decode(wide(0xFA02, 0xF30F)) == null);
    try std.testing.expect(shift_reg.group.decode(wide(0xFA0F, 0xF083)) == null); // SXTH.W
}
