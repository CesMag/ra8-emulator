//! Covers src/chip/core/cpu/ops/mov_wide.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const regs = ra8.chip.core.cpu.regs;
const mov_wide = ra8.chip.core.cpu.ops.mov_wide;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = mov_wide.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

fn fresh() Cpu {
    return .{ .bus = undefined, .regs = .{ .xpsr = regs.xpsr_bits.thumb | 0xF000_0000 } };
}

test "imm16 assembles imm4:i:imm3:imm8" {
    try std.testing.expectEqual(@as(u16, 0xA502), mov_wide.imm16(wide(0xF24A, 0x5202)));
    try std.testing.expectEqual(@as(u16, 0x1234), mov_wide.imm16(wide(0xF241, 0x2134)));
    try std.testing.expectEqual(@as(u16, 0x0800), mov_wide.imm16(wide(0xF640, 0x0000)));
    try std.testing.expectEqual(@as(u16, 0xFFFF), mov_wide.imm16(wide(0xF64F, 0x70FF)));
}

test "movw r2, #0xa502 replaces the whole register, flags untouched" {
    var cpu = fresh();
    cpu.regs.low[2] = 0xDEAD_BEEF;
    try run(&cpu, 0xF24A, 0x5202);
    try std.testing.expectEqual(@as(u32, 0xA502), cpu.regs.low[2]);
    try std.testing.expectEqual(regs.xpsr_bits.thumb | 0xF000_0000, cpu.regs.xpsr);
}

test "movt keeps the low half" {
    var cpu = fresh();
    cpu.regs.low[1] = 0xDEAD_1234;
    try run(&cpu, 0xF2C4, 0x0101); // movt r1, #0x4001
    try std.testing.expectEqual(@as(u32, 0x4001_1234), cpu.regs.low[1]);
}

test "movw reaches r12 and lr" {
    var cpu = fresh();
    try run(&cpu, 0xF241, 0x2C34);
    try std.testing.expectEqual(@as(u32, 0x1234), cpu.regs.get(12));
    try run(&cpu, 0xF241, 0x2E34);
    try std.testing.expectEqual(@as(u32, 0x1234), cpu.regs.get(14));
}

test "SP, PC, hw2[15] set and neighbours are not claimed" {
    const misses = [_]Instr{
        wide(0xF241, 0x2D34), // rd = sp
        wide(0xF241, 0x2F34), // rd = pc
        wide(0xF241, 0xA134), // hw2[15] set
        wide(0xF201, 0x0134), // addw
        wide(0xF2A1, 0x0134), // subw
        .{ .address = 0, .hw1 = 0xF241, .size = 2 },
    };
    for (misses) |instr| try std.testing.expect(mov_wide.group.decode(instr) == null);
}
