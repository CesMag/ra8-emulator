//! Covers src/chip/core/cpu/ops/ldr_literal_wide.zig.
const std = @import("std");
const ra8 = @import("ra8");
const lit = ra8.chip.core.cpu.ops.ldr.literal.wide;
const Instr = ra8.chip.core.cpu.instr.Instr;
const fixture = @import("../../../exception/ram.zig");

fn wide(address: u32, hw1: u16, hw2: u16) Instr {
    return .{ .address = address, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(ram: *fixture.Ram, instr: Instr) !ra8.chip.core.cpu.cpu.Cpu {
    var cpu = try fixture.boot(ram);
    try lit.group.decode(instr).?(&cpu, instr);
    return cpu;
}

test "ldr.w r9, [pc, #48] at a halfword-aligned address, the ra8_io_swap_demo encoding" {
    var ram: fixture.Ram = .{};
    // At code+2, PC reads code+6, aligned down to code+4; +0x30.
    ram.putWord(fixture.code + 4 + 0x30, 0xDEAD_BEEF);
    const cpu = try run(&ram, wide(fixture.code + 2, 0xF8DF, 0x9030));
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), cpu.regs.get(9));
}

test "U clear subtracts the offset" {
    var ram: fixture.Ram = .{};
    ram.putWord(fixture.code + 4 - 8, 0x1234_5678);
    const cpu = try run(&ram, wide(fixture.code, 0xF85F, 0x1008)); // ldr.w r1, [pc, #-8]
    try std.testing.expectEqual(@as(u32, 0x1234_5678), cpu.regs.get(1));
}

test "byte and halfword forms zero- or sign-extend" {
    var ram: fixture.Ram = .{};
    ram.putHalf(fixture.code + 4 + 0x10, 0x80F0);
    var cpu = try run(&ram, wide(fixture.code, 0xF89F, 0x2010)); // ldrb.w r2
    try std.testing.expectEqual(@as(u32, 0xF0), cpu.regs.get(2));
    cpu = try run(&ram, wide(fixture.code, 0xF99F, 0x2010)); // ldrsb.w r2
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF0), cpu.regs.get(2));
    cpu = try run(&ram, wide(fixture.code, 0xF8BF, 0x3010)); // ldrh.w r3
    try std.testing.expectEqual(@as(u32, 0x80F0), cpu.regs.get(3));
    cpu = try run(&ram, wide(fixture.code, 0xF9BF, 0x3010)); // ldrsh.w r3
    try std.testing.expectEqual(@as(u32, 0xFFFF_80F0), cpu.regs.get(3));
}

test "ldr.w pc, [pc, #imm] branches with interworking" {
    var ram: fixture.Ram = .{};
    ram.putWord(fixture.code + 4 + 0x20, fixture.handler | 1);
    const cpu = try run(&ram, wide(fixture.code, 0xF8DF, 0xF020));
    try std.testing.expectEqual(fixture.handler, cpu.regs.pc);
}

test "ldr.w sp, [pc, #imm] loads SP; the byte and halfword forms to SP stay unclaimed" {
    var ram: fixture.Ram = .{};
    ram.putWord(fixture.code + 4 + 0x10, 0x2000_1000);
    const cpu = try run(&ram, wide(fixture.code, 0xF8DF, 0xD010));
    try std.testing.expectEqual(@as(u32, 0x2000_1000), cpu.regs.get(13));
    try std.testing.expect(lit.form(wide(0, 0xF89F, 0xD010)) == null); // ldrb sp
    try std.testing.expect(lit.form(wide(0, 0xF8BF, 0xD010)) == null); // ldrh sp
}

test "PLD/PLI literal, other bases and stores stay unclaimed" {
    try std.testing.expect(lit.form(wide(0, 0xF89F, 0xF010)) == null); // pld
    try std.testing.expect(lit.form(wide(0, 0xF99F, 0xF010)) == null); // pli
    try std.testing.expect(lit.form(wide(0, 0xF8D0, 0x1010)) == null); // ldr.w r1, [r0]
    try std.testing.expect(lit.form(wide(0, 0xF8CF, 0x1010)) == null); // str, L clear
    try std.testing.expect(lit.form(wide(0, 0xF95F, 0x1010)) == null); // S with word size
    try std.testing.expect(lit.form(.{ .address = 0, .hw1 = 0xF8DF, .size = 2 }) == null);
}
