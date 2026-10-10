//! Covers src/chip/core/cpu/ops/bitfield.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const bitfield = ra8.chip.core.cpu.ops.bitfield;

fn wide(hw1: u16, hw2: u16) ra8.chip.core.cpu.instr.Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const exec = bitfield.group.decode(wide(hw1, hw2)) orelse return error.NotClaimed;
    try exec(cpu, wide(hw1, hw2));
}

test "ubfx r2, r1, #8, #8 is the blink_hal and threadx_blink encoding" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[1] = 0x1234_ABCD;
    try run(&cpu, 0xF3C1, 0x2207);
    try std.testing.expectEqual(@as(u32, 0xAB), cpu.regs.low[2]);
}

test "sbfx sign-extends the field and keeps a positive one" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[1] = 0x0000_0F00;
    try run(&cpu, 0xF341, 0x2203); // sbfx r2, r1, #8, #4
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), cpu.regs.low[2]);
    cpu.regs.low[1] = 0x0000_0700;
    try run(&cpu, 0xF341, 0x2203);
    try std.testing.expectEqual(@as(u32, 7), cpu.regs.low[2]);
}

test "a full-width extract returns Rn" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[1] = 0x8765_4321;
    try run(&cpu, 0xF3C1, 0x021F); // ubfx r2, r1, #0, #32
    try std.testing.expectEqual(@as(u32, 0x8765_4321), cpu.regs.low[2]);
    try run(&cpu, 0xF341, 0x031F); // sbfx r3, r1, #0, #32
    try std.testing.expectEqual(@as(u32, 0x8765_4321), cpu.regs.low[3]);
}

test "bfi inserts and bfc clears" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[1] = 0xFFFF_FF5A;
    cpu.regs.low[2] = 0x1111_1111;
    try run(&cpu, 0xF361, 0x120B); // bfi r2, r1, #4, #8 (msb 11)
    try std.testing.expectEqual(@as(u32, 0x1111_15A1), cpu.regs.low[2]);
    try run(&cpu, 0xF36F, 0x121F); // bfc r2, #4, #28 (msb 31)
    try std.testing.expectEqual(@as(u32, 0x0000_0001), cpu.regs.low[2]);
}

test "unpredictable forms stay unclaimed" {
    try std.testing.expect(bitfield.group.decode(wide(0xF3C1, 0x7F07)) == null); // lsb 28 + width 8
    try std.testing.expect(bitfield.group.decode(wide(0xF361, 0x2203)) == null); // msb below lsb
    try std.testing.expect(bitfield.group.decode(wide(0xF3C1, 0x2D07)) == null); // Rd = SP
    try std.testing.expect(bitfield.group.decode(wide(0xF3CF, 0x2207)) == null); // ubfx Rn = PC
    try std.testing.expect(bitfield.group.decode(wide(0xF3C1, 0x2227)) == null); // hw2[5] set
}
