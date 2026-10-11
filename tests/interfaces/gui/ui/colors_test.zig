//! RA8EMU-1082: the GUI's colours live in src/interfaces/gui/ui/colors.zig.
//! This guard fails if a Color.rgb literal with constant arguments shows up
//! anywhere else under src/interfaces/gui, so the palette stays in one file.
const std = @import("std");
const gui_app = @import("gui_app");

const root = "src/interfaces/gui";
const home = "ui/colors.zig";

test "no Color.rgb literal under src/interfaces/gui outside ui/colors.zig" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var found: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        if (std.mem.eql(u8, entry.path, home) or std.mem.eql(u8, entry.path, "ui\\colors.zig")) continue;
        const text = try dir.readFileAlloc(io, entry.path, allocator, .limited(1 << 20));
        defer allocator.free(text);
        found += literals(entry.path, text);
    }
    try std.testing.expectEqual(@as(usize, 0), found);
}

/// Counts `Color.rgb(` calls whose first argument is a number, printing each.
fn literals(path: []const u8, text: []const u8) usize {
    const needle = "Color.rgb(";
    var count: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, needle)) |hit| {
        at = hit + needle.len;
        if (at < text.len and std.ascii.isDigit(text[at])) {
            std.debug.print("{s}: colour literal at byte {d}\n", .{ path, hit });
            count += 1;
        }
    }
    return count;
}

test "the status tones are the palette's roles" {
    const colors = gui_app.colors;
    try std.testing.expectEqual(colors.muted, colors.tone.waiting);
    try std.testing.expectEqual(colors.accent, colors.tone.running);
    try std.testing.expectEqual(colors.highlight, colors.tone.halted);
}

test "semantic state and control tokens are defined" {
    const colors = gui_app.colors;
    try std.testing.expectEqual(colors.highlight, colors.dirty_register);
    try std.testing.expectEqual(colors.good, colors.run_lit);
    try std.testing.expectEqual(colors.highlight, colors.pause_lit);
    try std.testing.expectEqual(colors.pc_band_bg, colors.pc_band);
    try std.testing.expect(colors.breakpoint.r == 0xF4 and colors.breakpoint.g == 0x3F and colors.breakpoint.b == 0x5E);
    try std.testing.expect(colors.pc_cyan.r == 0x00 and colors.pc_cyan.g == 0xE5 and colors.pc_cyan.b == 0xFF);
    try std.testing.expect(colors.background.r == 0x0F and colors.background.g == 0x11 and colors.background.b == 0x17);
    try std.testing.expect(colors.border.r == 0x28 and colors.border.g == 0x2E and colors.border.b == 0x3C);
}
