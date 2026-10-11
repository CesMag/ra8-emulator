//! Covers src/chip/core/cpu/mve/modimm/modimm.zig.
const std = @import("std");
const ra8 = @import("ra8");
const modimm = ra8.chip.core.cpu.mve.modimm;

test "cmode and op pick the instruction" {
    try std.testing.expectEqual(modimm.Op.mov, modimm.kind(0, 0).?);
    try std.testing.expectEqual(modimm.Op.mvn, modimm.kind(1, 12).?);
    try std.testing.expectEqual(modimm.Op.orr, modimm.kind(0, 9).?);
    try std.testing.expectEqual(modimm.Op.bic, modimm.kind(1, 7).?);
    try std.testing.expectEqual(modimm.Op.mov, modimm.kind(1, 14).?);
    try std.testing.expectEqual(modimm.Op.mov, modimm.kind(0, 13).?);
}

test "cmode 1111 with op set is UNDEFINED" {
    try std.testing.expect(modimm.kind(1, 15) == null);
    try std.testing.expect(modimm.expand(1, 15, 0x70) == null);
    try std.testing.expect(modimm.run(1, 15, 0x70, 0) == null);
}

test "VMOV.I64 sets one byte per immediate bit" {
    try std.testing.expectEqual(~@as(u128, 0), modimm.expand(1, 14, 0xFF).?);
    try std.testing.expectEqual(@as(u128, 0), modimm.expand(1, 14, 0x00).?);
}

test "VORR and VBIC keep the bits the immediate does not touch" {
    const x: u128 = 0x12345678_9ABCDEF0_0F1E2D3C_4B5A6978;
    try std.testing.expectEqual(x, modimm.run(0, 1, 0, x).?);
    try std.testing.expectEqual(x, modimm.run(1, 1, 0, x).?);
}
