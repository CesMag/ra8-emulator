const std = @import("std");
const ra8 = @import("ra8");
const rounding = ra8.chip.core.cpu.fpu.rounding;

test "each FPSCR mode maps to the rounding of the same name" {
    try std.testing.expectEqual(rounding.Rounding.nearest, rounding.Rounding.of(.nearest));
    try std.testing.expectEqual(rounding.Rounding.plus_inf, rounding.Rounding.of(.plus_inf));
    try std.testing.expectEqual(rounding.Rounding.minus_inf, rounding.Rounding.of(.minus_inf));
    try std.testing.expectEqual(rounding.Rounding.zero, rounding.Rounding.of(.zero));
}

test "an exact cut never rounds up" {
    try std.testing.expect(!rounding.roundsUp(.{ .int = 3, .err = .none }, 0, .plus_inf));
}

test "a tie rounds up only from an odd magnitude to nearest even" {
    try std.testing.expect(rounding.roundsUp(.{ .int = 3, .err = .half }, 0, .nearest));
    try std.testing.expect(!rounding.roundsUp(.{ .int = 2, .err = .half }, 1, .nearest));
}

test "ties away rounds every tie up in magnitude" {
    try std.testing.expect(rounding.roundsUp(.{ .int = 2, .err = .half }, 1, .ties_away));
    try std.testing.expect(!rounding.roundsUp(.{ .int = 2, .err = .below_half }, 0, .ties_away));
}

test "the directed modes move the magnitude only toward their infinity" {
    try std.testing.expect(rounding.roundsUp(.{ .int = 2, .err = .below_half }, 1, .minus_inf));
    try std.testing.expect(!rounding.roundsUp(.{ .int = 2, .err = .above_half }, 1, .plus_inf));
}
