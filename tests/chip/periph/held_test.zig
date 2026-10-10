//! Tests for src/chip/periph/held.zig.
const std = @import("std");
const ra8 = @import("ra8");
const mod = ra8.chip.periph.held;

test "a controller that refused nothing is quiet" {
    const held = mod.Held{};
    try std.testing.expect(held.quiet());
    try std.testing.expectEqual(@as(u64, 0), held.total());
}

test "the total is every reason together" {
    const held = mod.Held{ .masked = 2, .outranked = 3, .deep = 1, .no_vector = 4 };
    try std.testing.expectEqual(@as(u64, 10), held.total());
    try std.testing.expect(!held.quiet());
}

test "the first outranked pairing is the one kept" {
    var held = mod.Held{};
    held.outrankedBy(14, 15);
    held.outrankedBy(14, 20);
    held.outrankedBy(31, 15);
    try std.testing.expectEqual(@as(u64, 3), held.outranked);
    try std.testing.expectEqual(@as(u16, 14), held.waiting);
    try std.testing.expectEqual(@as(u16, 15), held.winner);
}

test "a refusal for one reason leaves the others alone" {
    var held = mod.Held{};
    held.masked += 1;
    try std.testing.expectEqual(@as(u64, 0), held.outranked);
    try std.testing.expectEqual(@as(u16, 0), held.waiting);
    try std.testing.expectEqual(@as(u64, 1), held.total());
}
