//! Covers src/chip/core/cpu/ops/pkh.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const pkh = ra8.chip.core.cpu.ops.pkh;

fn wide(hw1: u16, hw2: u16) ra8.chip.core.cpu.instr.Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const exec = pkh.group.decode(wide(hw1, hw2)) orelse return error.NotClaimed;
    try exec(cpu, wide(hw1, hw2));
}

test "pkhbt r0, r1, r2 with and without a shift" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[1] = 0x1111_2222;
    cpu.regs.low[2] = 0x3333_4444;
    try run(&cpu, 0xEAC1, 0x0002);
    try std.testing.expectEqual(@as(u32, 0x3333_2222), cpu.regs.low[0]);
    try run(&cpu, 0xEAC1, 0x4002); // lsl #16
    try std.testing.expectEqual(@as(u32, 0x4444_2222), cpu.regs.low[0]);
}

test "pkhtb r0, r1, r2, asr #16 and asr #32" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[1] = 0x1111_2222;
    cpu.regs.low[2] = 0x8765_4444;
    try run(&cpu, 0xEAC1, 0x4022); // asr #16
    try std.testing.expectEqual(@as(u32, 0x1111_8765), cpu.regs.low[0]);
    try run(&cpu, 0xEAC1, 0x0022); // imm 0 is asr #32
    try std.testing.expectEqual(@as(u32, 0x1111_FFFF), cpu.regs.low[0]);
}

test "sp/pc and the reserved bits stay unclaimed" {
    try std.testing.expect(pkh.group.decode(wide(0xEACD, 0x0002)) == null); // Rn = SP
    try std.testing.expect(pkh.group.decode(wide(0xEAC1, 0x0F02)) == null); // Rd = PC
    try std.testing.expect(pkh.group.decode(wide(0xEAC1, 0x000D)) == null); // Rm = SP
    try std.testing.expect(pkh.group.decode(wide(0xEAC1, 0x0012)) == null); // hw2[4]
    try std.testing.expect(pkh.group.decode(wide(0xEAC1, 0x8002)) == null); // hw2[15]
    try std.testing.expect(pkh.group.decode(wide(0xEAD1, 0x0002)) == null); // S = 1
}
