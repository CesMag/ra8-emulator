//! Covers src/chip/core/cpu/ops/branch/branch.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const regs = ra8.chip.core.cpu.regs;
const flags = ra8.chip.core.cpu.flags;
const branch = ra8.chip.core.cpu.ops.branch;

fn run(cpu: *Cpu, address: u32, hw1: u16) !void {
    const instr: Instr = .{ .address = address, .hw1 = hw1, .size = 2 };
    const exec = branch.group.decode(instr) orelse return error.NotClaimed;
    cpu.regs.pc = address + 2; // as Cpu.step leaves it before exec
    try exec(cpu, instr);
}

fn fresh(apsr: u32) Cpu {
    return .{ .bus = undefined, .regs = .{ .xpsr = regs.xpsr_bits.thumb | apsr } };
}

test "bcc taken goes forward from address + 4" {
    var cpu = fresh(0);
    try run(&cpu, 0x020c0028, 0xD318); // bcc +0x30
    try std.testing.expectEqual(@as(u32, 0x020c005c), cpu.regs.pc);
}

test "bcc not taken falls through" {
    var cpu = fresh(flags.bits.c);
    try run(&cpu, 0x020c0028, 0xD318);
    try std.testing.expectEqual(@as(u32, 0x020c002a), cpu.regs.pc);
}

test "bne backwards with a negative imm8" {
    var cpu = fresh(0);
    try run(&cpu, 0x1000, 0xD1FE); // bne . (offset -4)
    try std.testing.expectEqual(@as(u32, 0x1000), cpu.regs.pc);
}

test "b reaches both ends of imm11" {
    var cpu = fresh(0);
    try run(&cpu, 0x1000, 0xE3FF); // +2046
    try std.testing.expectEqual(@as(u32, 0x1000 + 4 + 2046), cpu.regs.pc);
    try run(&cpu, 0x1000, 0xE400); // -2048
    try std.testing.expectEqual(@as(u32, 0x1000 + 4 - 2048), cpu.regs.pc);
}

test "UDF, SVC and neighbours are not claimed" {
    for ([_]u16{ 0xDE00, 0xDF01, 0xE800, 0xC000, 0xF000 }) |hw1| {
        try std.testing.expect(branch.group.decode(.{ .address = 0, .hw1 = hw1, .size = 2 }) == null);
    }
}
