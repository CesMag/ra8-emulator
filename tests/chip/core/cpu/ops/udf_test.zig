//! Covers src/chip/core/cpu/ops/udf.zig and the UNDEFINSTR UsageFault it raises
//! through Cpu.step.
const std = @import("std");
const ra8 = @import("ra8");
const udf = ra8.chip.core.cpu.ops.udf;
const memmap = ra8.chip.core.memmap;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const fixture = @import("../exception/ram.zig");

const usage_handler: u32 = fixture.base + 0x1C0;
const hard_handler: u32 = fixture.base + 0x1E0;
const usgfaultena: u32 = 1 << 18;
const undefinstr: u32 = 1 << 16;
const forced: u32 = 1 << 30;

fn claims(hw1: u16, hw2: u16, size: u3) bool {
    return udf.group.decode(.{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = size }) != null;
}

/// A core whose reset PC holds `word`, with UsageFault and HardFault aimed
/// at their handlers.
fn booted(ram: *fixture.Ram, word: u32) !Cpu {
    ram.putWord(fixture.base + 3 * 4, hard_handler | 1);
    ram.putWord(fixture.base + 6 * 4, usage_handler | 1);
    ram.putWord(fixture.code, word);
    return fixture.boot(ram);
}

test "UDF T1 claims every immediate and nothing beside it" {
    try std.testing.expect(claims(0xDE00, 0, 2));
    try std.testing.expect(claims(0xDEFF, 0, 2));
    try std.testing.expect(!claims(0xDF00, 0, 2)); // SVC
    try std.testing.expect(!claims(0xDD00, 0, 2)); // BLE
}

test "UDF T2 claims its 16-bit immediate and nothing beside it" {
    try std.testing.expect(claims(0xF7F0, 0xA000, 4));
    try std.testing.expect(claims(0xF7FF, 0xAFFF, 4));
    try std.testing.expect(!claims(0xF7F0, 0xB000, 4));
    try std.testing.expect(!claims(0xF7E0, 0xA000, 4));
    try std.testing.expect(!claims(0xF3BF, 0x8F4F, 4)); // DSB
}

test "the decode table reaches UDF for both encodings" {
    const decode = ra8.chip.core.cpu.decode.decode;
    try std.testing.expectEqualStrings("udf", decode(.{ .address = 0, .hw1 = 0xDE12, .size = 2 }).?.group);
    try std.testing.expectEqualStrings("udf", decode(.{ .address = 0, .hw1 = 0xF7F1, .hw2 = 0xA234, .size = 4 }).?.group);
}

test "UDF T1 is taken as UsageFault UNDEFINSTR with the UDF stacked" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, usgfaultena);
    var cpu = try booted(&ram, 0x0000_DE07);
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(usage_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 6), cpu.regs.xpsr & 0x1FF);
    try std.testing.expectEqual(undefinstr, ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.hfsr));
    try std.testing.expectEqual(fixture.code, ram.word(cpu.regs.sp() + 24));
}

test "UDF T2 with USGFAULTENA clear escalates to HardFault with HFSR.FORCED" {
    var ram: fixture.Ram = .{};
    var cpu = try booted(&ram, 0xA000_F7F0);
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(hard_handler, cpu.regs.pc);
    try std.testing.expectEqual(undefinstr, ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(forced, ram.word(memmap.scb.hfsr));
    try std.testing.expectEqual(fixture.code, ram.word(cpu.regs.sp() + 24));
}

test "UDF with FAULTMASK set locks up and stops on the UDF" {
    var ram: fixture.Ram = .{};
    var cpu = try booted(&ram, 0x0000_DE00);
    cpu.regs.faultmask = 1;
    const stop = cpu.step().?;
    try std.testing.expectEqual(@as(u16, 0xDE00), stop.unknown.hw1);
    try std.testing.expectEqual(fixture.code, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.cfsr));
}

test "UDF has no lockstep oracle" {
    try std.testing.expect(!udf.group.oracle);
}
