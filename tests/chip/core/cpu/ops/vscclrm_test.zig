//! Covers src/chip/core/cpu/ops/vscclrm.zig. Encodings checked against
//! arm-none-eabi-as -march=armv8.1-m.main+mve.fp+fp.dp.
const std = @import("std");
const ra8 = @import("ra8");
const vscclrm = ra8.chip.core.cpu.ops.vscclrm;
const table = ra8.chip.core.cpu.ops.table;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const fixture = @import("../exception/ram.zig");

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = fixture.code, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn exec(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    try vscclrm.group.decode(wide(hw1, hw2)).?(cpu, wide(hw1, hw2));
}

const sfpa = ra8.chip.core.cpu.regs.control_bits.sfpa;

/// A core with every S register non-zero, VPR set, and an active Secure FP
/// context (CONTROL.SFPA), so VSCCLRM has something to clear.
fn filled(ram: *fixture.Ram) !Cpu {
    var cpu = try fixture.boot(ram);
    cpu.regs.control |= sfpa;
    var n: u6 = 0;
    while (n < 32) : (n += 1) cpu.fp.bank.writeS(@intCast(n), 0x3F80_0000 + @as(u32, n));
    cpu.fp.vpr = @bitCast(@as(u32, 0x00FF_ABCD));
    return cpu;
}

/// Each S register is zero inside [first, first + count) and untouched
/// outside it, and VPR is zero.
fn expectCleared(cpu: *const Cpu, first: u6, count: u6) !void {
    var n: u6 = 0;
    while (n < 32) : (n += 1) {
        const inside = n >= first and n < first + count;
        const want: u32 = if (inside) 0 else 0x3F80_0000 + @as(u32, n);
        try std.testing.expectEqual(want, cpu.fp.bank.readS(@intCast(n)));
    }
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(cpu.fp.vpr)));
}

test "vscclrm {vpr} clears VPR alone" {
    var ram: fixture.Ram = .{};
    var cpu = try filled(&ram);
    try exec(&cpu, 0xEC9F, 0x0B00);
    try expectCleared(&cpu, 0, 0);
}

test "single runs: s0-s15 (the ra8_nsc veneer), s1, s31, s0-s31" {
    const cases = [_]struct { hw1: u16, hw2: u16, first: u6, count: u6 }{
        .{ .hw1 = 0xEC9F, .hw2 = 0x0A10, .first = 0, .count = 16 },
        .{ .hw1 = 0xECDF, .hw2 = 0x0A01, .first = 1, .count = 1 },
        .{ .hw1 = 0xECDF, .hw2 = 0xFA01, .first = 31, .count = 1 },
        .{ .hw1 = 0xEC9F, .hw2 = 0x0A20, .first = 0, .count = 32 },
    };
    for (cases) |c| {
        var ram: fixture.Ram = .{};
        var cpu = try filled(&ram);
        try exec(&cpu, c.hw1, c.hw2);
        try expectCleared(&cpu, c.first, c.count);
    }
}

test "double runs: d0-d7 and d8-d15" {
    var ram: fixture.Ram = .{};
    var cpu = try filled(&ram);
    try exec(&cpu, 0xEC9F, 0x0B10);
    try expectCleared(&cpu, 0, 16);
    var ram2: fixture.Ram = .{};
    var cpu2 = try filled(&ram2);
    try exec(&cpu2, 0xEC9F, 0x8B10);
    try expectCleared(&cpu2, 16, 16);
}

test "runs past the bank and odd double counts stay unclaimed" {
    const unclaimed = [_][2]u16{
        .{ 0xECDF, 0xFA02 }, // s31 plus one
        .{ 0xEC9F, 0x0A21 }, // 33 singles
        .{ 0xEC9F, 0x8B12 }, // d8 plus nine
        .{ 0xEC9F, 0x0B03 }, // odd imm8, double
        .{ 0xECDF, 0x0B02 }, // d16
    };
    for (unclaimed) |e| try std.testing.expect(vscclrm.group.decode(wide(e[0], e[1])) == null);
}

test "the table routes the veneer's vscclrm to this group alone" {
    var claimed: usize = 0;
    for (table.groups) |g| {
        if (g.decode(wide(0xEC9F, 0x0A10)) == null) continue;
        claimed += 1;
        try std.testing.expectEqualStrings("vscclrm", g.name);
    }
    try std.testing.expectEqual(@as(usize, 1), claimed);
}

test "vscclrm with ASPEN set and SFPA clear is a NOP" {
    var ram: fixture.Ram = .{};
    var cpu = try filled(&ram);
    cpu.regs.control &= ~sfpa;
    const control = cpu.regs.control;
    try std.testing.expect(vscclrm.idle(&cpu));
    try exec(&cpu, 0xEC9F, 0x0A10);
    var n: u6 = 0;
    while (n < 32) : (n += 1) try std.testing.expectEqual(0x3F80_0000 + @as(u32, n), cpu.fp.bank.readS(@intCast(n)));
    try std.testing.expectEqual(@as(u32, 0x00FF_ABCD), @as(u32, @bitCast(cpu.fp.vpr)));
    try std.testing.expectEqual(control, cpu.regs.control);
}

test "vscclrm with ASPEN clear clears even without SFPA" {
    var ram: fixture.Ram = .{};
    var cpu = try filled(&ram);
    cpu.regs.control &= ~sfpa;
    cpu.fp.context.fpccr.aspen = 0;
    try std.testing.expect(!vscclrm.idle(&cpu));
    try exec(&cpu, 0xEC9F, 0x0A10);
    try expectCleared(&cpu, 0, 16);
}
