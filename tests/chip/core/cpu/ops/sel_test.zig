//! Covers src/chip/core/cpu/ops/sel.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const sel = ra8.chip.core.cpu.ops.sel;
const xpsr_bits = ra8.chip.core.cpu.regs.xpsr_bits;

fn wide(hw1: u16, hw2: u16) ra8.chip.core.cpu.instr.Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

test "sel r0, r1, r2 picks bytes by GE" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.xpsr |= 0x5 << xpsr_bits.ge_shift;
    cpu.regs.low[1] = 0x1122_3344;
    cpu.regs.low[2] = 0xAABB_CCDD;
    const exec = sel.group.decode(wide(0xFAA1, 0xF082)) orelse return error.NotClaimed;
    try exec(&cpu, wide(0xFAA1, 0xF082));
    try std.testing.expectEqual(@as(u32, 0xAA22_CC44), cpu.regs.low[0]);
}

test "result covers all-set and all-clear GE" {
    try std.testing.expectEqual(@as(u32, 0x1122_3344), sel.result(0xF, 0x1122_3344, 0xAABB_CCDD));
    try std.testing.expectEqual(@as(u32, 0xAABB_CCDD), sel.result(0x0, 0x1122_3344, 0xAABB_CCDD));
}

test "sp/pc and other hw2 rows stay unclaimed" {
    try std.testing.expect(sel.group.decode(wide(0xFAAD, 0xF082)) == null); // Rn = SP
    try std.testing.expect(sel.group.decode(wide(0xFAA1, 0xF08F)) == null); // Rm = PC
    try std.testing.expect(sel.group.decode(wide(0xFAA1, 0xF002)) == null); // parallel row
}
