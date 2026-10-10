//! Covers src/chip/core/cpu/ops/divide.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const regs = ra8.chip.core.cpu.regs;
const divide = ra8.chip.core.cpu.ops.divide;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = divide.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

fn fresh() Cpu {
    return .{ .bus = undefined, .regs = .{ .xpsr = regs.xpsr_bits.thumb | 0xF000_0000 } };
}

test "udiv r6, r0, r1 is the blink_hal encoding and truncates" {
    var cpu = fresh();
    cpu.regs.low[0] = 100;
    cpu.regs.low[1] = 7;
    try run(&cpu, 0xFBB0, 0xF6F1);
    try std.testing.expectEqual(@as(u32, 14), cpu.regs.low[6]);
    try std.testing.expectEqual(regs.xpsr_bits.thumb | 0xF000_0000, cpu.regs.xpsr);
}

test "udiv treats operands as unsigned" {
    try std.testing.expectEqual(@as(u32, 0x7FFF_FFFF), divide.unsignedQuotient(0xFFFF_FFFF, 2));
}

test "sdiv r2, r3, r4 rounds toward zero" {
    var cpu = fresh();
    cpu.regs.low[3] = @bitCast(@as(i32, -7));
    cpu.regs.low[4] = 2;
    try run(&cpu, 0xFB93, 0xF2F4);
    try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, -3))), cpu.regs.low[2]);
}

test "a zero divisor gives zero with DIV_0_TRP clear" {
    try std.testing.expectEqual(@as(u32, 0), divide.unsignedQuotient(5, 0));
    try std.testing.expectEqual(@as(u32, 0), divide.signedQuotient(5, 0));
}

test "sdiv of INT_MIN by -1 wraps to INT_MIN" {
    try std.testing.expectEqual(@as(u32, 0x8000_0000), divide.signedQuotient(0x8000_0000, 0xFFFF_FFFF));
}

test "SP or PC in a field and a wrong hw2 stay unclaimed" {
    try std.testing.expect(divide.group.decode(wide(0xFBB0, 0xFDF1)) == null);
    try std.testing.expect(divide.group.decode(wide(0xFBBF, 0xF6F1)) == null);
    try std.testing.expect(divide.group.decode(wide(0xFBB0, 0xF6FD)) == null);
    try std.testing.expect(divide.group.decode(wide(0xFBB0, 0x06F1)) == null);
}
