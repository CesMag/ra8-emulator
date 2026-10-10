//! GIF LZW encoder: round trips through the test decoder, code widening,
//! table clears and the size of a flat panel frame.
const std = @import("std");
const ra8 = @import("ra8");
const lzw = ra8.board.report.gif.lzw;
const lzw_decode = @import("gif_lzw_decode.zig");

fn roundTrip(indices: []const u8) !usize {
    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(std.testing.allocator);
    try lzw.encode(std.testing.allocator, indices, &encoded);
    const decoded = try lzw_decode.decode(std.testing.allocator, encoded.items);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, indices, decoded);
    return encoded.items.len;
}

test "LZW round-trips empty, short and repeating inputs" {
    _ = try roundTrip(&.{});
    _ = try roundTrip(&.{7});
    _ = try roundTrip("TOBEORNOTTOBEORTOBEORNOT");
    // A run of one value takes the code-equals-next path on every new entry.
    _ = try roundTrip(&(@as([5000]u8, @splat(0x41))));
}

test "LZW widens past 9 bits and clears the table at 4096 codes" {
    const indices = try std.testing.allocator.alloc(u8, 40_000);
    defer std.testing.allocator.free(indices);
    var prng = std.Random.DefaultPrng.init(0x5eed_0583);
    prng.random().bytes(indices);
    const size = try roundTrip(indices);
    // Random bytes barely compress, so this many codes forces several clears.
    try std.testing.expect(size > indices.len);
}

test "a flat 1024x600 frame encodes to a few KB" {
    const indices = try std.testing.allocator.alloc(u8, 1024 * 600);
    defer std.testing.allocator.free(indices);
    @memset(indices, 0xE0);
    const size = try roundTrip(indices);
    try std.testing.expect(size < 4096);
}

test "the stream starts with clear and is deterministic" {
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(std.testing.allocator);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(std.testing.allocator);
    try lzw.encode(std.testing.allocator, "abcabcabc", &a);
    try lzw.encode(std.testing.allocator, "abcabcabc", &b);
    try std.testing.expectEqualSlices(u8, a.items, b.items);
    try std.testing.expectEqual(lzw.clear, @as(u16, a.items[0]) | (@as(u16, a.items[1] & 1) << 8));
}
