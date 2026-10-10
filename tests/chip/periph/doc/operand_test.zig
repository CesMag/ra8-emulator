//! Tests for src/chip/periph/doc/operand.zig.
const std = @import("std");
const ra8 = @import("ra8");
const mod = ra8.chip.periph.doc.operand;

test "the operand is two bytes with DOBW clear and four with it set" {
    try std.testing.expectEqual(@as(u32, 2), mod.operandBytes(false));
    try std.testing.expectEqual(@as(u32, 4), mod.operandBytes(true));
}

test "a store has to start at the bottom of the register" {
    for ([_]u32{ 1, 2, 3 }) |lane| {
        try std.testing.expect(!mod.carriedBy(lane, 4, false));
        try std.testing.expect(!mod.carriedBy(lane, 4, true));
    }
}

test "a 16-bit operand rides a halfword store and anything wider" {
    try std.testing.expect(mod.carriedBy(0, 2, false));
    try std.testing.expect(mod.carriedBy(0, 4, false));
    try std.testing.expect(!mod.carriedBy(0, 1, false));
}

test "a 32-bit operand needs the whole word" {
    try std.testing.expect(mod.carriedBy(0, 4, true));
    try std.testing.expect(!mod.carriedBy(0, 2, true));
    try std.testing.expect(!mod.carriedBy(0, 1, true));
}

test "the halfword ra8_doc.c writes through a uint16_t pointer carries" {
    // volatile uint16_t* dodir = (volatile uint16_t*)&reg->DODIR, with
    // DOCR.DOBW clear: lane 0, two bytes wide, 16-bit operand.
    try std.testing.expect(mod.carriedBy(0, 2, false));
}
