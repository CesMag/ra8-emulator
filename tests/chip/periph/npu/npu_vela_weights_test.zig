//! Tests for src/chip/periph/npu/npu_vela_weights.zig. Every stream here was
//! produced by Vela 3.12.0's own mlw_codec `encode`, and each expected list
//! is the weights handed to it, which its `decode` also returns.
const std = @import("std");
const ra8 = @import("ra8");
const weights = ra8.chip.periph.npu_vela.weights;

fn expectDecode(comptime hex: []const u8, expected: []const i16) !void {
    var stream: [hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&stream, hex);
    const got = try weights.decode(std.testing.allocator, &stream);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualSlices(i16, expected, got);
}

test "uncompressed indices with no zero runs" {
    try expectDecode("4e005c7004af563482bb1ca0fcffffff", &.{ 0, 1, -1, 2, -2, 3, 0, 0, 5, -7 });
}

test "zero runs around a pair of weights" {
    const zeros = @as([20]i16, @splat(0)) ++ [_]i16{ 4, -4 } ++ @as([5]i16, @splat(0));
    try expectDecode("03005c149438900800e00c80ffffffff", &zeros);
}

test "a four-entry palette" {
    try expectDecode("ee00dc35bca0944c5ba35c4085e60e40ffffffffffffffffffffffffffffffff", &.{
        37, 37, 90,   -5,   -100, -100, -5, 90,   37, 37, -5, -5, -5, 37, 37,
        37, -5, -100, -100, 37,   -100, 90, -100, 90, -5, -5, -5, -5, -5, 37,
    });
}

test "Golomb-Rice coded wide weights, truncated" {
    try expectDecode("be00ec72ef7d7b67c275d95a0de9f1de3259991209aaf3054b14264148202820" ++
        "ea52f7b3be2afc8311ae647f6cf0ffff", &.{
        194, -68, -206, -237, -186, -2,  -144, -123, 239, 89, -32, 143,
        65,  182, -101, -40,  4,    171, -58,  38,   -76, 18, 44,  -47,
    });
}

test "Golomb-Rice with a zero divisor" {
    try expectDecode("ee006021c2c9462b249f3b90feffffff", &.{
        2, 1, -1, 2, 1, -1, 2,  2,  2, 1, 2,  -1, 2,  2, 2,
        1, 2, 2,  1, 2, 2,  -1, -1, 1, 1, -1, 2,  -1, 1, -1,
    });
}

test "large magnitudes through a palette" {
    try expectDecode("96005c300e2032649680b1b1b1f1ffff", &.{
        0, 0, 0, 200, -200, 0, 150, 200, -200, 0, 150, 200, -200, 0, 150, 200, -200, 0, 150,
    });
}

test "a stream that is only padding decodes to nothing" {
    const got = try weights.decode(std.testing.allocator, &.{ 0xff, 0xff });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 0), got.len);
}

test "a slice cut short is an underrun" {
    try std.testing.expectError(error.Underrun, weights.decode(std.testing.allocator, &.{ 0x4e, 0x00 }));
}

test "a reserved zero divisor is refused" {
    // ZDIV 5 is neither a Golomb-Rice divisor nor the disable code.
    try std.testing.expectError(error.BadHeader, weights.decode(std.testing.allocator, &.{ 0x05, 0x00, 0x00, 0x00 }));
}

test "the first slice must set up a palette" {
    // ZDIV 6, SLICELEN 0, WDIV 7, WTRUNC 0, NEWPAL 0.
    try std.testing.expectError(error.BadHeader, weights.decode(std.testing.allocator, &.{ 0x06, 0x00, 0x1c, 0x00 }));
}
