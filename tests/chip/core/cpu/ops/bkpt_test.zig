//! Covers src/chip/core/cpu/ops/bkpt.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bkpt = ra8.chip.core.cpu.ops.bkpt;

fn claims(hw1: u16, size: u3) bool {
    return bkpt.group.decode(.{ .address = 0, .hw1 = hw1, .size = size }) != null;
}

test "BKPT claims every immediate and nothing beside it" {
    try std.testing.expect(claims(0xBE00, 2));
    try std.testing.expect(claims(0xBEAB, 2));
    try std.testing.expect(claims(0xBEFF, 2));
    try std.testing.expect(!claims(0xBF00, 2)); // NOP
    try std.testing.expect(!claims(0xBD00, 2)); // POP
    try std.testing.expect(!claims(0xBE00, 4));
}

test "the decode table reaches BKPT" {
    const hit = ra8.chip.core.cpu.decode.decode(.{ .address = 0, .hw1 = 0xBE01, .size = 2 }).?;
    try std.testing.expectEqualStrings("bkpt", hit.group);
    try std.testing.expect(!hit.oracle);
}
