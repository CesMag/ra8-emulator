//! Covers src/chip/core/cpu/ops/preload.zig.
const std = @import("std");
const ra8 = @import("ra8");
const preload = ra8.chip.core.cpu.ops.preload;
const Instr = ra8.chip.core.cpu.instr.Instr;
const fixture = @import("../exception/ram.zig");

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = fixture.code, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn expectKind(expected: preload.Kind, hw1: u16, hw2: u16) !void {
    try std.testing.expectEqual(@as(?preload.Kind, expected), preload.kind(wide(hw1, hw2)));
}

test "the immediate forms: T1 imm12 and T2 negative imm8" {
    try expectKind(.pld, 0xF890, 0xF010); // pld [r0, #16]
    try expectKind(.pldw, 0xF8B0, 0xF010); // pldw [r0, #16]
    try expectKind(.pli, 0xF990, 0xF010); // pli [r0, #16]
    try expectKind(.pld, 0xF810, 0xFC08); // pld [r0, #-8]
    try expectKind(.pldw, 0xF830, 0xFC08); // pldw [r0, #-8]
    try expectKind(.pli, 0xF910, 0xFC08); // pli [r0, #-8]
}

test "the literal forms, with U set and clear" {
    try expectKind(.pld, 0xF89F, 0xF010); // pld [pc, #16]
    try expectKind(.pld, 0xF81F, 0xF010); // pld [pc, #-16]
    try expectKind(.pli, 0xF99F, 0xF010); // pli [pc, #16]
    try expectKind(.pli, 0xF91F, 0xF010); // pli [pc, #-16]
}

test "the register forms" {
    try expectKind(.pld, 0xF810, 0xF021); // pld [r0, r1, lsl #2]
    try expectKind(.pldw, 0xF830, 0xF001); // pldw [r0, r1]
    try expectKind(.pli, 0xF910, 0xF031); // pli [r0, r1, lsl #3]
}

test "Rm of SP or PC, PLI with W, literal with W, other Rt and index forms stay unclaimed" {
    const cases = [_][2]u16{
        .{ 0xF810, 0xF00D }, // pld [r0, sp]
        .{ 0xF810, 0xF00F }, // pld [r0, pc]
        .{ 0xF930, 0xF010 }, // ldrsh pc: unallocated hint
        .{ 0xF8BF, 0xF010 }, // ldrh pc, literal: unallocated hint
        .{ 0xF890, 0xE010 }, // ldrb lr, [r0, #16]
        .{ 0xF810, 0xF910 }, // post-indexed byte load to pc
        .{ 0xF800, 0xF010 }, // a store
        .{ 0xF8D0, 0xF010 }, // ldr.w pc, [r0, #16]
    };
    for (cases) |c| try std.testing.expect(preload.kind(wide(c[0], c[1])) == null);
    try std.testing.expect(preload.kind(.{ .address = 0, .hw1 = 0xF890, .size = 2 }) == null);
}

test "a preload changes no register and makes no bus access, even at an unmapped address" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    cpu.regs.set(0, 0xFFFF_0000); // nothing is mapped there
    cpu.regs.set(1, 0x40);
    const before = cpu.regs;
    const instrs = [_]Instr{ wide(0xF890, 0xF010), wide(0xF810, 0xF021), wide(0xF99F, 0xF010) };
    for (instrs) |instr| try preload.group.decode(instr).?(&cpu, instr);
    try std.testing.expectEqual(before, cpu.regs);
}
