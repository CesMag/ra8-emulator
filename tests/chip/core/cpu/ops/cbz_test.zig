//! Covers src/chip/core/cpu/ops/cbz.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const cbz = ra8.chip.core.cpu.ops.cbz;

fn at(hw1: u16) Instr {
    return .{ .address = 0x0200_1000, .hw1 = hw1, .size = 2 };
}

fn run(cpu: *Cpu, hw1: u16) !void {
    const exec = cbz.group.decode(at(hw1)) orelse return error.NotClaimed;
    cpu.regs.pc = 0x0200_1002;
    try exec(cpu, at(hw1));
}

test "offset joins i and imm5 with a zero bit, up to 126" {
    try std.testing.expectEqual(@as(u32, 10), cbz.offset(0xB128));
    try std.testing.expectEqual(@as(u32, 126), cbz.offset(0xB3F8));
    try std.testing.expectEqual(@as(u32, 0), cbz.offset(0xB100));
}

test "cbz r0 branches when r0 is zero and falls through otherwise" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[0] = 0;
    try run(&cpu, 0xB128); // cbz r0, +10
    try std.testing.expectEqual(@as(u32, 0x0200_100E), cpu.regs.pc);
    cpu.regs.low[0] = 5;
    try run(&cpu, 0xB128);
    try std.testing.expectEqual(@as(u32, 0x0200_1002), cpu.regs.pc);
}

test "cbnz r3 branches when r3 is not zero and leaves the flags alone" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[3] = 1;
    cpu.regs.xpsr = 0x6100_0000;
    try run(&cpu, 0xBB03 | (2 << 3)); // cbnz r3, +68 (i=1, imm5=2)
    try std.testing.expectEqual(@as(u32, 0x0200_1000 + 4 + 68), cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0x6100_0000), cpu.regs.xpsr);
    cpu.regs.low[3] = 0;
    try run(&cpu, 0xBB13);
    try std.testing.expectEqual(@as(u32, 0x0200_1002), cpu.regs.pc);
}

test "leaves its neighbours alone" {
    for ([_]u16{ 0xB000, 0xB200, 0xB400, 0xBF00, 0xBA00 }) |hw1| {
        try std.testing.expect(cbz.group.decode(at(hw1)) == null);
    }
}
