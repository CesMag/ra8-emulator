//! Covers src/interfaces/cli/gif_out.zig: `--gif-out` writes the encoder's
//! bytes to the file it opens, the same bytes for the same frames, and a
//! size the format cannot hold is refused before the file is created.
const std = @import("std");
const cli_app = @import("cli_app");
const gif_out = cli_app.gif_out;
const gif = cli_app.report.gif;

const first = [_]u32{ 0xFF11_2233, 0xFFAA_BBCC };
const second = [_]u32{ 0xFFFF_0000, 0xFF00_FFFF };

fn write(path: []const u8) !void {
    var writer = try gif_out.Writer.init(std.testing.allocator, std.testing.io, path, 2, 1);
    defer writer.deinit();
    try writer.record(2, 1, &first, 1_000_000);
    try writer.record(2, 1, &second, 31_000_000);
    try writer.finish();
}

test "the file holds exactly what the encoder writes, the same on every run" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path_a = try std.fs.path.join(std.testing.allocator, &.{ root, "a.gif" });
    defer std.testing.allocator.free(path_a);
    const path_b = try std.fs.path.join(std.testing.allocator, &.{ root, "b.gif" });
    defer std.testing.allocator.free(path_b);
    try write(path_a);
    try write(path_b);
    const a = try temp.dir.readFileAlloc(std.testing.io, "a.gif", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(a);
    const b = try temp.dir.readFileAlloc(std.testing.io, "b.gif", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualSlices(u8, a, b);

    var expected = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer expected.deinit();
    var encoder = try gif.Encoder.init(std.testing.allocator, &expected.writer, 2, 1);
    defer encoder.deinit();
    try encoder.record(2, 1, &first, 1_000_000);
    try encoder.record(2, 1, &second, 31_000_000);
    try encoder.finish();
    try std.testing.expectEqualSlices(u8, expected.written(), a);
}

test "a size the format cannot hold is refused and no file is created" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "bad.gif" });
    defer std.testing.allocator.free(path);
    try std.testing.expectError(error.BadShape, gif_out.Writer.init(std.testing.allocator, std.testing.io, path, 0, 1));
    try std.testing.expectError(error.FileNotFound, temp.dir.access(std.testing.io, "bad.gif", .{}));
}
