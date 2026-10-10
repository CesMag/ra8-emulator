//! Covers src/chip/core/cpu/ops/special_data.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const regs = ra8.chip.core.cpu.regs;
const flags = ra8.chip.core.cpu.flags;
const special_data = ra8.chip.core.cpu.ops.special_data;

const thumb = regs.xpsr_bits.thumb;

fn run(cpu: *Cpu, address: u32, hw1: u16) !void {
    const instr: Instr = .{ .address = address, .hw1 = hw1, .size = 2 };
    const exec = special_data.group.decode(instr) orelse return error.NotClaimed;
    cpu.regs.pc = address + 2; // as Cpu.step leaves it before exec
    try exec(cpu, instr);
}

fn fresh() Cpu {
    return .{ .bus = undefined, .regs = .{ .xpsr = thumb } };
}

test "mov r4, r2 (0x4614) copies without touching flags" {
    var cpu = fresh();
    cpu.regs.xpsr |= flags.bits.z;
    cpu.regs.low[2] = 0x1234;
    try run(&cpu, 0x020c003e, 0x4614);
    try std.testing.expectEqual(@as(u32, 0x1234), cpu.regs.low[4]);
    try std.testing.expectEqual(thumb | flags.bits.z, cpu.regs.xpsr);
}

test "mov r8, r1 and mov r0, r12 reach the high registers" {
    var cpu = fresh();
    cpu.regs.low[1] = 7;
    try run(&cpu, 0, 0x4688);
    try std.testing.expectEqual(@as(u32, 7), cpu.regs.get(8));
    cpu.regs.set(12, 9);
    try run(&cpu, 0, 0x4660);
    try std.testing.expectEqual(@as(u32, 9), cpu.regs.low[0]);
}

test "mov r0, pc reads the address plus 4" {
    var cpu = fresh();
    try run(&cpu, 0x1000, 0x4678);
    try std.testing.expectEqual(@as(u32, 0x1004), cpu.regs.low[0]);
}

test "add pc, r0 branches and keeps the T bit" {
    var cpu = fresh();
    cpu.regs.low[0] = 0x10;
    try run(&cpu, 0x1000, 0x4487);
    try std.testing.expectEqual(@as(u32, 0x1014), cpu.regs.pc);
    try std.testing.expectEqual(thumb, cpu.regs.xpsr);
}

test "add r9, r9, r3 wraps" {
    var cpu = fresh();
    cpu.regs.set(9, 0xFFFF_FFFF);
    cpu.regs.low[3] = 2;
    try run(&cpu, 0, 0x4499);
    try std.testing.expectEqual(@as(u32, 1), cpu.regs.get(9));
}

test "cmp r8, r1 sets flags" {
    var cpu = fresh();
    cpu.regs.set(8, 1);
    cpu.regs.low[1] = 2;
    try run(&cpu, 0, 0x4588);
    try std.testing.expectEqual(thumb | flags.bits.n, cpu.regs.xpsr);
}

test "bx lr returns and takes T from bit 0" {
    var cpu = fresh();
    cpu.regs.set(14, 0x2001);
    try run(&cpu, 0x1000, 0x4770);
    try std.testing.expectEqual(@as(u32, 0x2000), cpu.regs.pc);
    try std.testing.expectEqual(thumb, cpu.regs.xpsr);
    cpu.regs.set(14, 0x3000);
    try run(&cpu, 0x1000, 0x4770);
    try std.testing.expectEqual(@as(u32, 0x3000), cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.xpsr & thumb);
}

test "blx r3 links past itself and jumps" {
    var cpu = fresh();
    cpu.regs.low[3] = 0x4001;
    try run(&cpu, 0x1000, 0x4798);
    try std.testing.expectEqual(@as(u32, 0x1003), cpu.regs.get(14));
    try std.testing.expectEqual(@as(u32, 0x4000), cpu.regs.pc);
}

test "blx lr reads the old lr" {
    var cpu = fresh();
    cpu.regs.set(14, 0x5001);
    try run(&cpu, 0x1000, 0x47F0);
    try std.testing.expectEqual(@as(u32, 0x5000), cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0x1003), cpu.regs.get(14));
}

test "UNPREDICTABLE, BXNS/BLXNS and neighbours are not claimed" {
    for ([_]u16{ 0x44FF, 0x4511, 0x45F8, 0x478F, 0x47FF, 0x4774, 0x4784, 0x43FF, 0x4800 }) |hw1| {
        try std.testing.expect(special_data.group.decode(.{ .address = 0, .hw1 = hw1, .size = 2 }) == null);
    }
}
