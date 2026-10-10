//! Covers src/chip/core/cpu/ops/saturate.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const xpsr_bits = ra8.chip.core.cpu.regs.xpsr_bits;
const saturate = ra8.chip.core.cpu.ops.saturate;

fn wide(hw1: u16, hw2: u16) ra8.chip.core.cpu.instr.Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const exec = saturate.group.decode(wide(hw1, hw2)) orelse return error.NotClaimed;
    try exec(cpu, wide(hw1, hw2));
}

test "ssat r0, #8, r1 clamps both ways and sets Q" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[1] = 300;
    try run(&cpu, 0xF301, 0x0007);
    try std.testing.expectEqual(@as(u32, 127), cpu.regs.low[0]);
    try std.testing.expect(cpu.regs.xpsr & xpsr_bits.q != 0);
    cpu.regs.low[1] = @bitCast(@as(i32, -300));
    try run(&cpu, 0xF301, 0x0007);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FF80), cpu.regs.low[0]);
}

test "an in-range value passes and leaves Q clear" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[1] = @bitCast(@as(i32, -5));
    try run(&cpu, 0xF301, 0x0007);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFB), cpu.regs.low[0]);
    try std.testing.expect(cpu.regs.xpsr & xpsr_bits.q == 0);
}

test "usat clamps negatives to zero and applies the shifts" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[1] = @bitCast(@as(i32, -1));
    try run(&cpu, 0xF381, 0x0008); // usat r0, #8, r1
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.low[0]);
    try std.testing.expect(cpu.regs.xpsr & xpsr_bits.q != 0);
    cpu.regs.low[1] = 0x100;
    try run(&cpu, 0xF3A1, 0x1008); // usat r0, #8, r1, asr #4
    try std.testing.expectEqual(@as(u32, 0x10), cpu.regs.low[0]);
    try run(&cpu, 0xF381, 0x0088); // usat r0, #8, r1, lsl #2
    try std.testing.expectEqual(@as(u32, 0xFF), cpu.regs.low[0]);
}

test "ssat #32 and usat #0 are the range edges" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[1] = 0x8000_0000;
    try run(&cpu, 0xF301, 0x001F); // ssat r0, #32, r1
    try std.testing.expectEqual(@as(u32, 0x8000_0000), cpu.regs.low[0]);
    try std.testing.expect(cpu.regs.xpsr & xpsr_bits.q == 0);
    cpu.regs.low[1] = 5;
    try run(&cpu, 0xF381, 0x0000); // usat r0, #0, r1
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.low[0]);
}

test "sp/pc, the 16-bit forms and MSR stay unclaimed" {
    try std.testing.expect(saturate.group.decode(wide(0xF30D, 0x0007)) == null); // Rn = SP
    try std.testing.expect(saturate.group.decode(wide(0xF301, 0x0F07)) == null); // Rd = PC
    try std.testing.expect(saturate.group.decode(wide(0xF321, 0x0007)) == null); // SSAT16
    try std.testing.expect(saturate.group.decode(wide(0xF3A1, 0x0007)) == null); // USAT16
    try std.testing.expect(saturate.group.decode(wide(0xF381, 0x8800)) == null); // MSR
}
