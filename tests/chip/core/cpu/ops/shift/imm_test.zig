//! Covers src/chip/core/cpu/ops/shift_imm.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const regs = ra8.chip.core.cpu.regs;
const flags = ra8.chip.core.cpu.flags;
const shift_imm = ra8.chip.core.cpu.ops.shift.imm;

fn run(cpu: *Cpu, hw1: u16) !void {
    const instr: ra8.chip.core.cpu.instr.Instr = .{ .address = 0, .hw1 = hw1, .size = 2 };
    const exec = shift_imm.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

fn fresh() Cpu {
    return .{ .bus = undefined, .regs = .{ .xpsr = regs.xpsr_bits.thumb } };
}

test "lsls r0, r1, #1 shifts out bit 31 into C and sets N" {
    var cpu = fresh();
    cpu.regs.low[1] = 0xC000_0000;
    try run(&cpu, 0x0048);
    try std.testing.expectEqual(@as(u32, 0x8000_0000), cpu.regs.low[0]);
    try std.testing.expectEqual(regs.xpsr_bits.thumb | flags.bits.n | flags.bits.c, cpu.regs.xpsr);
}

test "movs r2, r3 (lsl #0) sets N and Z and keeps C" {
    var cpu = fresh();
    cpu.regs.xpsr |= flags.bits.c | flags.bits.v;
    try run(&cpu, 0x001A);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.low[2]);
    try std.testing.expectEqual(regs.xpsr_bits.thumb | flags.bits.z | flags.bits.c | flags.bits.v, cpu.regs.xpsr);
}

test "lsrs and asrs #0 shift by 32" {
    var cpu = fresh();
    cpu.regs.low[1] = 0x8000_0000;
    try run(&cpu, 0x0808); // lsrs r0, r1, #32
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.low[0]);
    try std.testing.expectEqual(regs.xpsr_bits.thumb | flags.bits.z | flags.bits.c, cpu.regs.xpsr);
    try run(&cpu, 0x100A); // asrs r2, r1, #32
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), cpu.regs.low[2]);
    try std.testing.expectEqual(regs.xpsr_bits.thumb | flags.bits.n | flags.bits.c, cpu.regs.xpsr);
}

test "inside an IT block the flags stay put" {
    var cpu = fresh();
    cpu.regs.xpsr |= 1 << 12;
    cpu.regs.low[1] = 0xC000_0000;
    try run(&cpu, 0x0048);
    try std.testing.expectEqual(@as(u32, 0x8000_0000), cpu.regs.low[0]);
    try std.testing.expectEqual(regs.xpsr_bits.thumb | (1 << 12), cpu.regs.xpsr);
}

test "add/sub and other encodings are not claimed" {
    for ([_]u16{ 0x1800, 0x1C00, 0x1E00, 0x2000, 0x4000 }) |hw1| {
        try std.testing.expect(shift_imm.group.decode(.{ .address = 0, .hw1 = hw1, .size = 2 }) == null);
    }
}
