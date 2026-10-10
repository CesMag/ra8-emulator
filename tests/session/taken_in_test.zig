//! Tests for src/session/taken_in.zig.
const std = @import("std");
const ra8 = @import("ra8");
const taken_in = ra8.session.taken_in;

test "a window holds its own range and nothing either side" {
    const window = taken_in.Window{ .base = 0x0200_22A6, .size = 0x20 };
    try std.testing.expect(!window.holds(0x0200_22A5));
    try std.testing.expect(window.holds(0x0200_22A6));
    try std.testing.expect(window.holds(0x0200_22C4));
    try std.testing.expect(!window.holds(0x0200_22C6));
}

test "the one-off a tally would have thrown away is kept" {
    var window = taken_in.Window{ .base = 0x0200_22A6, .size = 0x20 };
    window.record(0x0200_22B6, 15);
    try std.testing.expectEqual(@as(u64, 1), window.seen);
    const kept = window.kept();
    try std.testing.expectEqual(@as(usize, 1), kept.len);
    try std.testing.expectEqual(@as(u32, 0x0200_22B6), kept[0].pc);
    try std.testing.expectEqual(@as(u32, 15), kept[0].number);
    try std.testing.expectEqual(@as(u64, 1), kept[0].at);
    try std.testing.expectEqual(@as(u64, 0), window.missed());
}

test "a pc outside the window is not recorded even if offered" {
    var window = taken_in.Window{ .base = 0x0200_22A6, .size = 0x20 };
    window.record(0x0200_1000, 15);
    try std.testing.expectEqual(@as(u64, 0), window.seen);
    try std.testing.expectEqual(@as(usize, 0), window.kept().len);
}

test "a busy window keeps the first entries and counts the rest" {
    var window = taken_in.Window{ .base = 0x1000, .size = 0x100 };
    for (0..taken_in.limits.kept + 7) |index| {
        window.record(@intCast(0x1000 + (index % 4) * 4), 15);
    }
    try std.testing.expectEqual(@as(u64, taken_in.limits.kept + 7), window.seen);
    try std.testing.expectEqual(taken_in.limits.kept, window.kept().len);
    try std.testing.expectEqual(@as(u64, 7), window.missed());
    // Oldest first, so the ordinals run from one.
    try std.testing.expectEqual(@as(u64, 1), window.kept()[0].at);
    try std.testing.expectEqual(@as(u64, taken_in.limits.kept), window.kept()[taken_in.limits.kept - 1].at);
}

test "a window nobody asked for resolves to nothing" {
    const headless: [64]u8 = @splat(0);
    const image = ra8.board.image.elf.Image{ .bytes = &headless };
    try std.testing.expectEqual(@as(?taken_in.Window, null), taken_in.resolve(image, null));
}
