//! Covers src/chip/core/cpu/ops/long_shift_reg.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const long_shift_reg = ra8.chip.core.cpu.ops.long.shift.reg;
const table = ra8.chip.core.cpu.ops.table;

/// lsll r2, r3, r4 and asrl r2, r3, r4, as arm-none-eabi-as encodes them.
const lsll_hw2: u16 = 0x430D;
const asrl_hw2: u16 = 0x432D;

fn wide(hw1: u16, hw2: u16) ra8.chip.core.cpu.instr.Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

/// Runs the op on r2:r3 = lo:hi shifted by r4, with a known xPSR; returns
/// hi:lo and checks r4 and the flags are untouched.
fn run(hw2: u16, value: u64, amount: u32) !u64 {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[2] = @truncate(value);
    cpu.regs.low[3] = @truncate(value >> 32);
    cpu.regs.low[4] = amount;
    cpu.regs.xpsr = 0xF100_0000;
    const instr = wide(0xEA52, hw2);
    const exec = long_shift_reg.group.decode(instr) orelse return error.NotClaimed;
    try exec(&cpu, instr);
    try std.testing.expectEqual(@as(u32, 0xF100_0000), cpu.regs.xpsr);
    try std.testing.expectEqual(amount, cpu.regs.low[4]);
    return (@as(u64, cpu.regs.low[3]) << 32) | cpu.regs.low[2];
}

test "lsll r2, r3, r4 decodes its registers" {
    const f = long_shift_reg.fields(wide(0xEA52, lsll_hw2)).?;
    try std.testing.expectEqual(@as(u4, 2), f.lo);
    try std.testing.expectEqual(@as(u4, 3), f.hi);
    try std.testing.expectEqual(@as(u4, 4), f.rm);
    try std.testing.expectEqual(long_shift_reg.Kind.lsll, f.kind);
    try std.testing.expectEqual(long_shift_reg.Kind.asrl, long_shift_reg.fields(wide(0xEA52, asrl_hw2)).?.kind);
}

test "lsll shifts left for a positive amount and right for a negative one" {
    try std.testing.expectEqual(@as(u64, 0xF_0000_0000), try run(lsll_hw2, 0xF000_0000, 4));
    try std.testing.expectEqual(@as(u64, 0x0800_0000_0000_0000), try run(lsll_hw2, 0x8000_0000_0000_0000, 0xFFFF_FFFC));
}

test "asrl shifts right with the sign for a positive amount and left for a negative one" {
    try std.testing.expectEqual(@as(u64, 0xF800_0000_0000_0000), try run(asrl_hw2, 0x8000_0000_0000_0000, 4));
    try std.testing.expectEqual(@as(u64, 0x10), try run(asrl_hw2, 1, 0xFFFF_FFFC));
}

test "only the bottom byte of Rm counts, and zero leaves the pair alone" {
    try std.testing.expectEqual(@as(u64, 0x10), try run(lsll_hw2, 1, 0x0000_0104));
    try std.testing.expectEqual(@as(u64, 0x1234_5678_9ABC_DEF0), try run(asrl_hw2, 0x1234_5678_9ABC_DEF0, 0x100));
}

test "a shift of 64 or more empties the pair or fills it with the sign" {
    try std.testing.expectEqual(@as(u64, 0), try run(lsll_hw2, ~@as(u64, 0), 64));
    try std.testing.expectEqual(@as(u64, 0), try run(lsll_hw2, ~@as(u64, 0), 0x80));
    try std.testing.expectEqual(~@as(u64, 0), try run(asrl_hw2, 0x8000_0000_0000_0000, 100));
    try std.testing.expectEqual(@as(u64, 0), try run(asrl_hw2, 0x7FFF_FFFF_FFFF_FFFF, 127));
    try std.testing.expectEqual(@as(u64, 0), try run(asrl_hw2, ~@as(u64, 0), 0xC0));
}

test "the forms this group leaves alone" {
    const left = [_][2]u16{
        .{ 0xEA52, 0x4F0D }, // RdaHi 1111: UQRSHL
        .{ 0xEA53, 0x430D }, // hw1 bit 0 set: UQRSHLL
        .{ 0xEA52, 0x431D }, // type 01
        .{ 0xEA52, 0x433D }, // type 11
        .{ 0xEA52, 0x434D }, // hw2 bit 6 set
        .{ 0xEA52, 0x438D }, // hw2 bit 7 set
        .{ 0xEA52, 0xD30D }, // Rm = SP
        .{ 0xEA52, 0xF30D }, // Rm = PC
        .{ 0xEA52, 0x230D }, // Rm = RdaLo
        .{ 0xEA52, 0x330D }, // Rm = RdaHi
        .{ 0xEA52, 0x134F }, // the immediate form
    };
    for (left) |pair| try std.testing.expect(long_shift_reg.group.decode(wide(pair[0], pair[1])) == null);
}

test "no earlier group claims the register forms" {
    for (table.groups) |g| {
        if (g.decode(wide(0xEA52, lsll_hw2)) == null) continue;
        try std.testing.expectEqualStrings("long_shift_reg", g.name);
        break;
    }
}

test "the group has a lockstep oracle" {
    try std.testing.expect(long_shift_reg.group.oracle);
}

test "seam port: asrl r2, r3, r12 reads the amount and leaves Rm alone" {
    var cpu: ra8.chip.core.cpu.cpu.Cpu = .{ .bus = undefined };
    cpu.regs.low[3] = 0x8000_0000;
    cpu.regs.set(12, 4);
    const instr: ra8.chip.core.cpu.instr.Instr = .{ .address = 0, .hw1 = 0xEA52, .hw2 = 0xC32D, .size = 4 };
    const exec = ra8.chip.core.cpu.ops.long.shift.reg.group.decode(instr) orelse return error.NotClaimed;
    try exec(&cpu, instr);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.low[2]);
    try std.testing.expectEqual(@as(u32, 0xF800_0000), cpu.regs.low[3]);
    try std.testing.expectEqual(@as(u32, 4), cpu.regs.get(12));
}
