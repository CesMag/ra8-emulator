//! Covers src/chip/core/cpu/ops/extend_wide.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const extend_wide = ra8.chip.core.cpu.ops.extend_wide;

fn wide(hw1: u16, hw2: u16) ra8.chip.core.cpu.instr.Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const exec = extend_wide.group.decode(wide(hw1, hw2)) orelse return error.NotClaimed;
    try exec(cpu, wide(hw1, hw2));
}

test "uxtb.w and sxtb.w r0, r1 with no rotation" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[1] = 0x1234_5680;
    try run(&cpu, 0xFA5F, 0xF081);
    try std.testing.expectEqual(@as(u32, 0x80), cpu.regs.low[0]);
    try run(&cpu, 0xFA4F, 0xF081);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FF80), cpu.regs.low[0]);
}

test "the rotation picks the byte or halfword" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[1] = 0x8899_AABB;
    try run(&cpu, 0xFA5F, 0xF0A1); // uxtb r0, r1, ror #16
    try std.testing.expectEqual(@as(u32, 0x99), cpu.regs.low[0]);
    try run(&cpu, 0xFA0F, 0xF0B1); // sxth r0, r1, ror #24
    try std.testing.expectEqual(@as(u32, 0xFFFF_BB88), cpu.regs.low[0]);
    try run(&cpu, 0xFA1F, 0xF0A1); // uxth r0, r1, ror #16
    try std.testing.expectEqual(@as(u32, 0x8899), cpu.regs.low[0]);
}

test "the accumulating forms add Rn and wrap" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[1] = 0x0000_00FF;
    cpu.regs.low[2] = 0xFFFF_FF02;
    try run(&cpu, 0xFA42, 0xF081); // sxtab r0, r2, r1
    try std.testing.expectEqual(@as(u32, 0xFFFF_FF01), cpu.regs.low[0]);
    try run(&cpu, 0xFA52, 0xF081); // uxtab r0, r2, r1
    try std.testing.expectEqual(@as(u32, 0x0000_0001), cpu.regs.low[0]);
    cpu.regs.low[1] = 0x0001_0000;
    try run(&cpu, 0xFA12, 0xF0A1); // uxtah r0, r2, r1, ror #16
    try std.testing.expectEqual(@as(u32, 0xFFFF_FF03), cpu.regs.low[0]);
}

test "sp/pc, the DSP rows and a set hw2[6] stay unclaimed" {
    try std.testing.expect(extend_wide.group.decode(wide(0xFA5F, 0xFD81)) == null); // Rd = SP
    try std.testing.expect(extend_wide.group.decode(wide(0xFA5F, 0xF08F)) == null); // Rm = PC
    try std.testing.expect(extend_wide.group.decode(wide(0xFA5D, 0xF081)) == null); // Rn = SP
    try std.testing.expect(extend_wide.group.decode(wide(0xFA2F, 0xF081)) == null); // SXTB16
    try std.testing.expect(extend_wide.group.decode(wide(0xFA3F, 0xF081)) == null); // UXTB16
    try std.testing.expect(extend_wide.group.decode(wide(0xFA5F, 0xF0C1)) == null); // hw2[6] set
}
