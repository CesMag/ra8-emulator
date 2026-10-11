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
    for ([_]*const gui_app.colors.Theme{ &gui_app.colors.palettes.dark, &gui_app.colors.palettes.light }) |theme| {
        try std.testing.expectEqual(theme.muted, theme.tone().waiting);
        try std.testing.expectEqual(theme.accent, theme.tone().running);
        try std.testing.expectEqual(theme.highlight, theme.tone().halted);
        try std.testing.expectEqual(theme.highlight, theme.dirtyRegister());
        try std.testing.expectEqual(theme.good, theme.runLit());
        try std.testing.expectEqual(theme.highlight, theme.pauseLit());
    }
}

test "dark is Cesar's Instrument Bench palette and the default choice" {
    const dark = &gui_app.colors.palettes.dark;
    try std.testing.expect(dark.breakpoint.r == 0xF4 and dark.breakpoint.g == 0x3F and dark.breakpoint.b == 0x5E);
    try std.testing.expect(dark.pc_cyan.r == 0x00 and dark.pc_cyan.g == 0xE5 and dark.pc_cyan.b == 0xFF);
    try std.testing.expect(dark.background.r == 0x0F and dark.background.g == 0x11 and dark.background.b == 0x17);
    try std.testing.expect(dark.border.r == 0x28 and dark.border.g == 0x2E and dark.border.b == 0x3C);
    try std.testing.expectEqual(dark, gui_app.colors.of(.dark));
}

test "light is a light surface with dark ink" {
    const light = gui_app.colors.of(.light);
    try std.testing.expect(light.background.r > 0xF0 and light.background.g > 0xF0 and light.background.b > 0xF0);
    try std.testing.expect(light.ink.r < 0x20 and light.ink.g < 0x20 and light.ink.b < 0x40);
}
