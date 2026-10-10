//! Covers src/board/snapshot/stretch.zig (RA8EMU-700).
const std = @import("std");
const ra8 = @import("ra8");
const file = ra8.snapshot.file;
const stretch = ra8.board.snapshot.stretch;

test "what a run owed comes back from its section" {
    var buf: [64]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    try file.writeHeader(&stream);
    try stretch.save(.{ .owed = 123_456, .cycle_remainder = 789, .boundary_hz = 8_000_000 }, &stream);
    const expected: stretch.State = .{ .owed = 123_456, .cycle_remainder = 789, .rate_known = true, .boundary_hz = 8_000_000 };
    try std.testing.expectEqual(expected, try stretch.load(stream.buffered()));
}

test "an unscaled open boundary remains unscaled" {
    var buf: [64]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    try file.writeHeader(&stream);
    try stretch.save(.{ .owed = 123_456 }, &stream);
    const expected: stretch.State = .{ .owed = 123_456, .rate_known = true };
    try std.testing.expectEqual(expected, try stretch.load(stream.buffered()));
}

test "a file with no stretch section owes nothing" {
    var buf: [16]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    try file.writeHeader(&stream);
    try std.testing.expectEqual(stretch.State{}, try stretch.load(stream.buffered()));
}

test "an old stretch section loads without a fractional cycle" {
    var buf: [32]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    try file.writeHeader(&stream);
    try file.writeSectionHeader(&stream, .stretch, @sizeOf(u32));
    try stream.writeInt(u32, 123_456, .little);
    const expected: stretch.State = .{ .owed = 123_456, .rate_known = true };
    try std.testing.expectEqual(expected, try stretch.load(stream.buffered()));
}

test "an old fractional stretch section loads without a boundary rate" {
    var buf: [64]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    try file.writeHeader(&stream);
    try file.writeSectionHeader(&stream, .stretch, @sizeOf(u32) + @sizeOf(u64));
    try stream.writeInt(u32, 123_456, .little);
    try stream.writeInt(u64, 789, .little);
    const expected: stretch.State = .{ .owed = 123_456, .cycle_remainder = 789 };
    try std.testing.expectEqual(expected, try stretch.load(stream.buffered()));
}

test "a stretch section of the wrong size is refused" {
    var buf: [64]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    try file.writeHeader(&stream);
    try file.writeSectionHeader(&stream, .stretch, 2);
    try stream.writeAll(&.{ 1, 2 });
    try std.testing.expectError(error.BadValue, stretch.load(stream.buffered()));
}
