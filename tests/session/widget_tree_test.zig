//! RA8EMU-713: the widget-tree header accepts protocol v1 (64 records) and
//! v2 (256 records, RA8FW-782) and rejects anything else.
const std = @import("std");
const ra8 = @import("ra8");
const tree = ra8.session.widget_tree;

fn header(version: u16, count: u16, truncated: bool) [tree.records_offset]u8 {
    var bytes: [tree.records_offset]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], tree.magic, .little);
    std.mem.writeInt(u16, bytes[4..6], version, .little);
    std.mem.writeInt(u16, bytes[6..8], count, .little);
    std.mem.writeInt(u32, bytes[8..12], 9, .little);
    bytes[12] = @intFromBool(truncated);
    return bytes;
}

test "v1 header holds at most 64 records" {
    const full = header(1, 64, false);
    try std.testing.expectEqual(@as(u16, 64), (try tree.parseHeader(&full)).count);
    const over = header(1, 65, false);
    try std.testing.expectError(error.InvalidWidgetTree, tree.parseHeader(&over));
}

test "v2 header holds up to 256 records and reports truncation" {
    const many = header(2, 200, true);
    const parsed = try tree.parseHeader(&many);
    try std.testing.expectEqual(tree.Header{ .version = 2, .count = 200, .generation = 9, .truncated = true }, parsed);
    const full = header(2, 256, false);
    try std.testing.expectEqual(@as(u16, 256), (try tree.parseHeader(&full)).count);
    const over = header(2, 257, false);
    try std.testing.expectError(error.InvalidWidgetTree, tree.parseHeader(&over));
}

test "unknown versions and a wrong magic are refused" {
    const v3 = header(3, 1, false);
    try std.testing.expectError(error.UnsupportedWidgetTree, tree.parseHeader(&v3));
    const v0 = header(0, 1, false);
    try std.testing.expectError(error.UnsupportedWidgetTree, tree.parseHeader(&v0));
    var bad = header(2, 1, false);
    bad[0] ^= 0xFF;
    try std.testing.expectError(error.InvalidWidgetTree, tree.parseHeader(&bad));
}
