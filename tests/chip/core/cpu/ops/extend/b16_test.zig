//! Covers src/chip/core/cpu/ops/extend_b16.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const extend_b16 = ra8.chip.core.cpu.ops.extend.b16;

fn wide(hw1: u16, hw2: u16) ra8.chip.core.cpu.instr.Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const exec = extend_b16.group.decode(wide(hw1, hw2)) orelse return error.NotClaimed;
    try exec(cpu, wide(hw1, hw2));
}

test "sxtb16 and uxtb16 r0, r1" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[1] = 0x1180_2281;
    try run(&cpu, 0xFA2F, 0xF081);
    try std.testing.expectEqual(@as(u32, 0xFF80_FF81), cpu.regs.low[0]);
    try run(&cpu, 0xFA3F, 0xF081);
    try std.testing.expectEqual(@as(u32, 0x0080_0081), cpu.regs.low[0]);
}

test "the rotation picks bytes 1 and 3" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[1] = 0x8811_7F22;
    try run(&cpu, 0xFA2F, 0xF091); // sxtb16 r0, r1, ror #8
    try std.testing.expectEqual(@as(u32, 0xFF88_007F), cpu.regs.low[0]);
}

test "the accumulating forms add per halfword and wrap in each lane" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[1] = 0x00FF_00FF;
    cpu.regs.low[2] = 0x0001_FFFF;
    try run(&cpu, 0xFA32, 0xF081); // uxtab16 r0, r2, r1
    try std.testing.expectEqual(@as(u32, 0x0100_00FE), cpu.regs.low[0]);
    try run(&cpu, 0xFA22, 0xF081); // sxtab16 r0, r2, r1
    try std.testing.expectEqual(@as(u32, 0x0000_FFFE), cpu.regs.low[0]);
}

test "sp/pc and the other extend rows stay unclaimed" {
    try std.testing.expect(extend_b16.group.decode(wide(0xFA3F, 0xFD81)) == null); // Rd = SP
    try std.testing.expect(extend_b16.group.decode(wide(0xFA3F, 0xF08F)) == null); // Rm = PC
    try std.testing.expect(extend_b16.group.decode(wide(0xFA3D, 0xF081)) == null); // Rn = SP
    try std.testing.expect(extend_b16.group.decode(wide(0xFA5F, 0xF081)) == null); // UXTB
    try std.testing.expect(extend_b16.group.decode(wide(0xFA3F, 0xF001)) == null); // hw2[7]
}
