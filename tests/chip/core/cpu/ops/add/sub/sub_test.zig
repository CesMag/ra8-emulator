//! Covers src/chip/core/cpu/ops/add_sub.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const regs = ra8.chip.core.cpu.regs;
const flags = ra8.chip.core.cpu.flags;
const add_sub = ra8.chip.core.cpu.ops.add.sub;

const thumb = regs.xpsr_bits.thumb;

fn run(cpu: *Cpu, hw1: u16) !void {
    const instr: ra8.chip.core.cpu.instr.Instr = .{ .address = 0, .hw1 = hw1, .size = 2 };
    const exec = add_sub.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

fn fresh() Cpu {
    return .{ .bus = undefined, .regs = .{ .xpsr = thumb } };
}

test "adds r0, r1, r2 carries and zeroes" {
    var cpu = fresh();
    cpu.regs.low[1] = 0xFFFF_FFFF;
    cpu.regs.low[2] = 1;
    try run(&cpu, 0x1888);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.low[0]);
    try std.testing.expectEqual(thumb | flags.bits.z | flags.bits.c, cpu.regs.xpsr);
}

test "subs r3, r4, #1 borrows below zero" {
    var cpu = fresh();
    try run(&cpu, 0x1E63);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), cpu.regs.low[3]);
    try std.testing.expectEqual(thumb | flags.bits.n, cpu.regs.xpsr);
}

test "subs r0, r1, r2 overflows from most negative" {
    var cpu = fresh();
    cpu.regs.low[1] = 0x8000_0000;
    cpu.regs.low[2] = 1;
    try run(&cpu, 0x1A88);
    try std.testing.expectEqual(@as(u32, 0x7FFF_FFFF), cpu.regs.low[0]);
    try std.testing.expectEqual(thumb | flags.bits.c | flags.bits.v, cpu.regs.xpsr);
}

test "movs r5, #0 sets Z and keeps C and V" {
    var cpu = fresh();
    cpu.regs.xpsr |= flags.bits.c | flags.bits.v;
    cpu.regs.low[5] = 9;
    try run(&cpu, 0x2500);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.low[5]);
    try std.testing.expectEqual(thumb | flags.bits.z | flags.bits.c | flags.bits.v, cpu.regs.xpsr);
}

test "cmp r2, #7 sets flags and leaves r2" {
    var cpu = fresh();
    cpu.regs.low[2] = 7;
    try run(&cpu, 0x2A07);
    try std.testing.expectEqual(@as(u32, 7), cpu.regs.low[2]);
    try std.testing.expectEqual(thumb | flags.bits.z | flags.bits.c, cpu.regs.xpsr);
}

test "cmp sets flags even inside an IT block, adds does not" {
    var cpu = fresh();
    const it: u32 = 1 << 12;
    cpu.regs.xpsr |= it;
    cpu.regs.low[2] = 3;
    try run(&cpu, 0x2A07); // cmp r2, #7
    try std.testing.expectEqual(thumb | it | flags.bits.n, cpu.regs.xpsr);
    cpu.regs.xpsr = thumb | it;
    try run(&cpu, 0x3201); // adds r2, #1
    try std.testing.expectEqual(@as(u32, 4), cpu.regs.low[2]);
    try std.testing.expectEqual(thumb | it, cpu.regs.xpsr);
}

test "adds and subs #imm8 update Rdn" {
    var cpu = fresh();
    cpu.regs.low[6] = 0x10;
    try run(&cpu, 0x36F0); // adds r6, #0xf0
    try std.testing.expectEqual(@as(u32, 0x100), cpu.regs.low[6]);
    try run(&cpu, 0x3EFF); // subs r6, #0xff
    try std.testing.expectEqual(@as(u32, 1), cpu.regs.low[6]);
    try std.testing.expectEqual(thumb | flags.bits.c, cpu.regs.xpsr);
}

test "shifts and other encodings are not claimed" {
    for ([_]u16{ 0x0048, 0x0808, 0x1000, 0x4000, 0x428B }) |hw1| {
        try std.testing.expect(add_sub.group.decode(.{ .address = 0, .hw1 = hw1, .size = 2 }) == null);
    }
}
