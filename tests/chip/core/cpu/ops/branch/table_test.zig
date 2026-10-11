//! Covers src/chip/core/cpu/ops/branch/table.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const table_branch = ra8.chip.core.cpu.ops.table_branch;
const ram_mod = @import("../../exception/ram.zig");

const here: u32 = ram_mod.code;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = here, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const exec = table_branch.group.decode(wide(hw1, hw2)) orelse return error.NotClaimed;
    cpu.regs.pc = here + 4;
    try exec(cpu, wide(hw1, hw2));
}

test "tbb [pc, r1] reads the byte table straight after it, the CDC encoding" {
    var ram: ram_mod.Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    ram.putWord(here + 4, 0x0C08_0402); // entries 2, 4, 8, 12
    cpu.regs.low[1] = 2;
    try run(&cpu, 0xE8DF, 0xF001);
    try std.testing.expectEqual(here + 4 + 16, cpu.regs.pc);
    cpu.regs.low[1] = 0;
    try run(&cpu, 0xE8DF, 0xF001);
    try std.testing.expectEqual(here + 4 + 4, cpu.regs.pc);
}

test "tbh [r2, r3, lsl #1] scales the index and reads a halfword" {
    var ram: ram_mod.Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    const table = ram_mod.base + 0x200;
    ram.putHalf(table + 6, 0x0123);
    cpu.regs.low[2] = table;
    cpu.regs.low[3] = 3;
    try run(&cpu, 0xE8D2, 0xF013);
    try std.testing.expectEqual(here + 4 + 0x246, cpu.regs.pc);
}

test "entry adds Rm, or Rm * 2 for TBH, to Rn" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[4] = 0x1000;
    cpu.regs.low[5] = 7;
    try std.testing.expectEqual(@as(u32, 0x1007), table_branch.entry(&cpu, wide(0xE8D4, 0xF005)));
    try std.testing.expectEqual(@as(u32, 0x100E), table_branch.entry(&cpu, wide(0xE8D4, 0xF015)));
}

test "unclaimed: Rn = SP, Rm = SP or PC, other hw2 bits, 16-bit" {
    try std.testing.expect(table_branch.group.decode(wide(0xE8DD, 0xF001)) == null);
    try std.testing.expect(table_branch.group.decode(wide(0xE8D1, 0xF00D)) == null);
    try std.testing.expect(table_branch.group.decode(wide(0xE8D1, 0xF00F)) == null);
    try std.testing.expect(table_branch.group.decode(wide(0xE8D1, 0xF041)) == null); // LDREXB
    try std.testing.expect(table_branch.group.decode(wide(0xE8D1, 0x0F01)) == null);
    const narrow: Instr = .{ .address = here, .hw1 = 0xE8DF, .size = 2 };
    try std.testing.expect(table_branch.group.decode(narrow) == null);
}
