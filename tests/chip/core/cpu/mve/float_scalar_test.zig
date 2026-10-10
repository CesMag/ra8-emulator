//! Covers src/chip/core/cpu/mve/float_scalar.zig.
const std = @import("std");
const ra8 = @import("ra8");
const float_scalar = ra8.chip.core.cpu.mve.float_scalar;

test "broadcast fills every lane" {
    try std.testing.expectEqual(@as(u128, 0x3C00_3C00_3C00_3C00_3C00_3C00_3C00_3C00), float_scalar.broadcast(0x12343C00, .half));
    try std.testing.expectEqual(@as(u128, 0x12345678_12345678_12345678_12345678), float_scalar.broadcast(0x12345678, .word));
}
