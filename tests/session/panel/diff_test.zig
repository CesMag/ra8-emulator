//! Tests for src/session/panel_diff.zig (RA8EMU-1126): the box of what
//! differs between two pictures, alpha left out, and null for the same one.
const std = @import("std");
const ra8 = @import("ra8");

const panel_diff = ra8.session.panel.diff;
const Rect = panel_diff.Rect;

/// A 4 by 3 picture of one colour.
fn plain(colour: u32) [12]u32 {
    return @splat(colour);
}

test "two pictures that show the same have no box, whatever their alpha" {
    const before = plain(0xFF10_2030);
    var after = plain(0xFF10_2030);
    try std.testing.expectEqual(@as(?Rect, null), panel_diff.box(&before, &after, 4));
    after[5] = 0x0010_2030;
    try std.testing.expectEqual(@as(?Rect, null), panel_diff.box(&before, &after, 4));
}

test "one changed pixel is a box of one" {
    const before = plain(0);
    var after = plain(0);
    after[2 * 4 + 3] = 1;
    try std.testing.expectEqual(@as(?Rect, .{ .x = 3, .y = 2, .width = 1, .height = 1 }), panel_diff.box(&before, &after, 4));
}

test "the box spans the outermost changed pixels and nothing more" {
    const before = plain(0);
    var after = plain(0);
    after[0 * 4 + 2] = 1;
    after[1 * 4 + 1] = 1;
    try std.testing.expectEqual(@as(?Rect, .{ .x = 1, .y = 0, .width = 2, .height = 2 }), panel_diff.box(&before, &after, 4));
    after[2 * 4 + 0] = 1;
    after[2 * 4 + 3] = 1;
    try std.testing.expectEqual(@as(?Rect, panel_diff.whole(4, 3)), panel_diff.box(&before, &after, 4));
}

test "pictures of different lengths, or no width, have no box to compare" {
    const before = plain(0);
    const after = [_]u32{ 1, 2 };
    try std.testing.expectEqual(@as(?Rect, null), panel_diff.box(&before, &after, 2));
    try std.testing.expectEqual(@as(?Rect, null), panel_diff.box(&before, &before, 0));
}

test "the whole panel is clamped to what a rectangle can say" {
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 1024, .height = 600 }, panel_diff.whole(1024, 600));
    try std.testing.expectEqual(@as(u16, 65535), panel_diff.whole(70_000, 1).width);
}
