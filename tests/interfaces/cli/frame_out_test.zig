//! Tests for src/interfaces/cli/frame_out.zig.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const frame_out = cli_app.report.frame_out;
const cli = cli_app.cli;

test "a saved frame goes out opaque whatever alpha the mixer left" {
    const pixels = [_]u32{ 0x0012_3456, 0x80AB_CDEF };
    var rgba: [8]u8 = undefined;
    try frame_out.opaqueRgba(&pixels, &rgba);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x34, 0x56, 0xFF, 0xAB, 0xCD, 0xEF, 0xFF }, &rgba);
}

test "--frame-out takes a path and is off by default" {
    try std.testing.expectEqual(@as(?[]const u8, null), (try cli.parse(&[_][]const u8{ "emu", "a.elf" })).frame_out);
    const given = try cli.parse(&[_][]const u8{ "emu", "a.elf", "--frame-out", "panel.png" });
    try std.testing.expectEqualStrings("panel.png", given.frame_out.?);
    try std.testing.expectError(error.MissingValue, cli.parse(&[_][]const u8{ "emu", "a.elf", "--frame-out" }));
    const panel_only = try cli.parse(&[_][]const u8{ "emu", "a.elf", "--panel-only" });
    try std.testing.expect(panel_only.panel_only);
}

test "--eink-log takes a path and is off by default" {
    try std.testing.expectEqual(@as(?[]const u8, null), (try cli.parse(&[_][]const u8{ "emu", "a.elf" })).frames.eink_log);
    const given = try cli.parse(&[_][]const u8{ "emu", "a.elf", "--eink-log", "refresh.jsonl" });
    try std.testing.expectEqualStrings("refresh.jsonl", given.frames.eink_log.?);
    try std.testing.expectError(error.MissingValue, cli.parse(&[_][]const u8{ "emu", "a.elf", "--eink-log" }));
}

test "no path means no line and no file" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    try frame_out.report(&buffer.writer, std.testing.io, undefined, null, false);
    try std.testing.expectEqual(@as(usize, 0), buffer.written().len);
}

test "a run with no panel frame still writes the board view with its LEDs" {
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "view.png" });
    defer std.testing.allocator.free(path);
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    try frame_out.report(&buffer.writer, std.testing.io, &board, path, false);
    try std.testing.expect(std.mem.startsWith(u8, buffer.written(), "frame-out: no panel frame, the LEDs on a 1056x664 board view"));
    var magic: [8]u8 = undefined;
    var view = try dir.dir.openFile(std.testing.io, "view.png", .{});
    defer view.close(std.testing.io);
    _ = try view.readPositionalAll(std.testing.io, &magic, 0);
    try std.testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", &magic);
}

test "--panel-only writes the dark fallback panel at its own size" {
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "panel.png" });
    defer std.testing.allocator.free(path);
    const saved = try frame_out.save(std.testing.allocator, std.testing.io, &board, path, true);
    try std.testing.expect(!saved.frame);
    try std.testing.expectEqual(@as(u32, 1024), saved.view.width);
    try std.testing.expectEqual(@as(u32, 600), saved.view.height);
    try std.testing.expectEqual(saved.width, saved.view.width);
    try std.testing.expectEqual(saved.height, saved.view.height);
    var file = try dir.dir.openFile(std.testing.io, "panel.png", .{});
    defer file.close(std.testing.io);
    var header: [24]u8 = undefined;
    _ = try file.readPositionalAll(std.testing.io, &header, 0);
    try std.testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", header[0..8]);
    try std.testing.expectEqual(@as(u32, 1024), std.mem.readInt(u32, header[16..20], .big));
    try std.testing.expectEqual(@as(u32, 600), std.mem.readInt(u32, header[20..24], .big));
}

test "attached e-ink frame-out writes the refreshed glass as grey PNG pixels" {
    const proto = ra8.components.eink_wire;
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    board.asks.attached_eink = &board.panel;
    board.panel.planes.resize(.{ .width = 128, .height = 128 });

    const panel = board.asks.attached_eink.?;
    word(panel, proto.preamble.command);
    word(panel, @backingInt(proto.Command.load_area));
    for ([_]u16{ 0x0030, 0, 0, 2, 1, 0x2211 }) |value| {
        word(panel, proto.preamble.write);
        word(panel, value);
    }
    word(panel, proto.preamble.command);
    word(panel, @backingInt(proto.Command.display_area));
    for ([_]u16{ 0, 0, 2, 1, 2 }) |value| {
        word(panel, proto.preamble.write);
        word(panel, value);
    }

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "eink.png" });
    defer std.testing.allocator.free(path);
    const saved = try frame_out.save(std.testing.allocator, std.testing.io, &board, path, false);
    try std.testing.expect(saved.frame);
    try std.testing.expectEqual(@as(u32, 128), saved.width);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &cli_app.report.png.signature, bytes[0..8]);
    const idat_len = std.mem.readInt(u32, bytes[33..37], .big);
    try std.testing.expectEqualStrings("IDAT", bytes[37..41]);
    var compressed: std.Io.Reader = .fixed(bytes[41 .. 41 + idat_len]);
    var raw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer raw.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflate: std.compress.flate.Decompress = .init(&compressed, .zlib, &window);
    _ = try inflate.reader.streamRemaining(&raw.writer);
    try std.testing.expectEqual(@as(u8, 0), raw.written()[0]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x11, 0x11, 0xFF, 0x22, 0x22, 0x22, 0xFF }, raw.written()[1..9]);
}

fn word(panel: anytype, value: u16) void {
    _ = panel.exchange(@intCast(value >> 8));
    _ = panel.exchange(@intCast(value & 0xFF));
}

test "with no attach and no GLCDC frame, frame-out saves the board's refreshed e-ink glass" {
    const proto = ra8.components.eink_wire;
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    board.panel.planes.resize(.{ .width = 16, .height = 8 });
    const panel = &board.panel;
    word(panel, proto.preamble.command);
    word(panel, @backingInt(proto.Command.load_area));
    for ([_]u16{ 0x0030, 0, 0, 2, 1, 0x2211 }) |value| {
        word(panel, proto.preamble.write);
        word(panel, value);
    }
    word(panel, proto.preamble.command);
    word(panel, @backingInt(proto.Command.display_area));
    for ([_]u16{ 0, 0, 2, 1, 2 }) |value| {
        word(panel, proto.preamble.write);
        word(panel, value);
    }

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "board_eink.png" });
    defer std.testing.allocator.free(path);
    const saved = try frame_out.save(std.testing.allocator, std.testing.io, &board, path, false);
    try std.testing.expect(saved.eink);
    try std.testing.expect(saved.frame);
    try std.testing.expectEqual(@as(u32, 16), saved.width);
    try std.testing.expectEqual(@as(u32, 8), saved.height);
}

test "an unrefreshed board panel leaves frame-out on the board view" {
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "view.png" });
    defer std.testing.allocator.free(path);
    const saved = try frame_out.save(std.testing.allocator, std.testing.io, &board, path, false);
    try std.testing.expect(!saved.eink);
    try std.testing.expect(!saved.frame);
}
