//! Tests for src/chip/periph/npu/vela/round.zig. The vectors come from a
//! Python transcription of tflite-micro's two MultiplyByQuantizedMultiplier
//! forms (common.cc at 1fae604). The scales and shifts are what Vela's
//! quantise_scale gives a per-channel int8 1x1 convolution, and the first
//! four accumulators land exactly on a .5 tie.
const std = @import("std");
const ra8 = @import("ra8");
const round = ra8.chip.periph.npu.vela.round;

const Vector = struct { acc: i64, scale: u32, shift: u6, double: i128, natural: i128, truncate: i128 };

const vectors = [_]Vector{
    .{ .acc = -21941, .scale = 1321694465, .shift = 38, .double = -106, .natural = -105, .truncate = -105 },
    .{ .acc = -2190, .scale = 1945001765, .shift = 38, .double = -16, .natural = -15, .truncate = -15 },
    .{ .acc = -19609, .scale = 1128422195, .shift = 38, .double = -81, .natural = -80, .truncate = -80 },
    .{ .acc = -14898, .scale = 1955825631, .shift = 40, .double = -27, .natural = -27, .truncate = -26 },
    .{ .acc = 21941, .scale = 1321694465, .shift = 38, .double = 106, .natural = 105, .truncate = 105 },
    .{ .acc = 126579, .scale = 1622305820, .shift = 45, .double = 6, .natural = 6, .truncate = 5 },
    .{ .acc = -12025, .scale = 1136030071, .shift = 38, .double = -50, .natural = -50, .truncate = -49 },
    .{ .acc = -69425, .scale = 1185095836, .shift = 31, .double = -38312, .natural = -38312, .truncate = -38312 },
    .{ .acc = -140648, .scale = 1872161983, .shift = 38, .double = -958, .natural = -958, .truncate = -957 },
    .{ .acc = -70725, .scale = 1891413223, .shift = 40, .double = -122, .natural = -122, .truncate = -121 },
    .{ .acc = -146537, .scale = 1609175468, .shift = 20, .double = -224879976, .natural = -224879976, .truncate = -224879975 },
    .{ .acc = 183350, .scale = 1539165521, .shift = 38, .double = 1027, .natural = 1027, .truncate = 1026 },
    .{ .acc = -53471, .scale = 1464746328, .shift = 38, .double = -285, .natural = -285, .truncate = -284 },
    .{ .acc = 0, .scale = 1073741824, .shift = 31, .double = 0, .natural = 0, .truncate = 0 },
    .{ .acc = -1, .scale = 1073741824, .shift = 31, .double = 0, .natural = 0, .truncate = 0 },
    .{ .acc = 1, .scale = 2147483647, .shift = 0, .double = 2147483647, .natural = 2147483647, .truncate = 2147483647 },
    .{ .acc = -3, .scale = 1073741824, .shift = 1, .double = -1610612736, .natural = -1610612736, .truncate = -1610612736 },
};

test "each mode matches the TFLM reference vectors" {
    for (vectors) |v| {
        try std.testing.expectEqual(v.double, round.apply(v.acc, v.scale, v.shift, .double));
        try std.testing.expectEqual(v.natural, round.apply(v.acc, v.scale, v.shift, .natural));
        try std.testing.expectEqual(v.truncate, round.apply(v.acc, v.scale, v.shift, .truncate));
    }
}

test "a tie splits double from natural rounding only when negative" {
    // -21941 * 1321694465 / 2^38 is -105.4988...: not a tie, but the
    // doubling high multiply leaves -105.5 for the second rounding.
    try std.testing.expectEqual(@as(i128, -106), round.apply(-21941, 1321694465, 38, .double));
    try std.testing.expectEqual(@as(i128, 106), round.apply(21941, 1321694465, 38, .double));
}

test "the precision field decodes three modes and refuses the fourth" {
    try std.testing.expectEqual(round.Rounding.double, round.Rounding.fromBits(0).?);
    try std.testing.expectEqual(round.Rounding.truncate, round.Rounding.fromBits(1).?);
    try std.testing.expectEqual(round.Rounding.natural, round.Rounding.fromBits(2).?);
    try std.testing.expect(round.Rounding.fromBits(3) == null);
}
