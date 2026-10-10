//! Covers src/chip/core/cpu/flags.zig.
const std = @import("std");
const ra8 = @import("ra8");
const flags = ra8.chip.core.cpu.flags;
const regs = ra8.chip.core.cpu.regs;

const Case = struct { x: u32, y: u32, c: bool, result: u32, carry: bool, overflow: bool };

test "AddWithCarry matches the pseudocode on the edge cases" {
    const cases = [_]Case{
        .{ .x = 1, .y = 2, .c = false, .result = 3, .carry = false, .overflow = false },
        .{ .x = 0xFFFF_FFFF, .y = 1, .c = false, .result = 0, .carry = true, .overflow = false },
        .{ .x = 0x7FFF_FFFF, .y = 1, .c = false, .result = 0x8000_0000, .carry = false, .overflow = true },
        .{ .x = 0x8000_0000, .y = 0x8000_0000, .c = false, .result = 0, .carry = true, .overflow = true },
        // 5 - 5 as 5 + NOT 5 + 1: no borrow, so C set
        .{ .x = 5, .y = ~@as(u32, 5), .c = true, .result = 0, .carry = true, .overflow = false },
        // 3 - 5: borrow, C clear
        .{ .x = 3, .y = ~@as(u32, 5), .c = true, .result = 0xFFFF_FFFE, .carry = false, .overflow = false },
        .{ .x = 0xFFFF_FFFF, .y = 0xFFFF_FFFF, .c = true, .result = 0xFFFF_FFFF, .carry = true, .overflow = false },
    };
    for (cases) |case| {
        const sum = flags.addWithCarry(case.x, case.y, case.c);
        try std.testing.expectEqual(case.result, sum.result);
        try std.testing.expectEqual(case.carry, sum.carry);
        try std.testing.expectEqual(case.overflow, sum.overflow);
    }
}

test "setting flags touches only NZCV" {
    var file: regs.Regs = .{ .xpsr = regs.xpsr_bits.thumb | 0x0F };
    flags.setNZCV(&file, .{ .result = 0, .carry = true, .overflow = true });
    try std.testing.expectEqual(regs.xpsr_bits.thumb | 0x0F | flags.bits.z | flags.bits.c | flags.bits.v, file.xpsr);
    flags.setNZ(&file, 0x8000_0000);
    try std.testing.expectEqual(regs.xpsr_bits.thumb | 0x0F | flags.bits.n | flags.bits.c | flags.bits.v, file.xpsr);
}

test "an IT block is any non-zero IT field" {
    var file: regs.Regs = .{ .xpsr = regs.xpsr_bits.thumb };
    try std.testing.expect(!flags.inItBlock(&file));
    file.xpsr |= 1 << 12;
    try std.testing.expect(flags.inItBlock(&file));
    file.xpsr = regs.xpsr_bits.thumb | (1 << 25);
    try std.testing.expect(flags.inItBlock(&file));
}
