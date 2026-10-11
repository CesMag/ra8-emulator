//! Covers src/interfaces/gui/window/keys.zig: Ctrl+Cmd+F toggles full
//! screen on macOS and F11 does elsewhere, and nothing else does (RA8EMU-966).
const std = @import("std");
const gui_app = @import("gui_app");
const keys = gui_app.window.keys;

test "Ctrl+Cmd+F toggles full screen on macOS and F11 does not" {
    try std.testing.expect(keys.togglesFullscreen(keys.letter_f, .{ .ctrl = true, .gui = true }, true));
    try std.testing.expect(!keys.togglesFullscreen(keys.letter_f, .{ .gui = true }, true));
    try std.testing.expect(!keys.togglesFullscreen(keys.letter_f, .{ .ctrl = true }, true));
    try std.testing.expect(!keys.togglesFullscreen(keys.letter_f, .{ .ctrl = true, .gui = true, .shift = true }, true));
    try std.testing.expect(!keys.togglesFullscreen(keys.f11, .{}, true));
}

test "F11 alone toggles full screen on Windows and Linux and Ctrl+Cmd+F does not" {
    try std.testing.expect(keys.togglesFullscreen(keys.f11, .{}, false));
    try std.testing.expect(!keys.togglesFullscreen(keys.f11, .{ .ctrl = true }, false));
    try std.testing.expect(!keys.togglesFullscreen(keys.f11, .{ .alt = true }, false));
    try std.testing.expect(!keys.togglesFullscreen(keys.letter_f, .{ .ctrl = true, .gui = true }, false));
    try std.testing.expect(!keys.togglesFullscreen('a', .{}, false));
}

test "a shortcut is held with Cmd on macOS and with Ctrl elsewhere" {
    try std.testing.expect(keys.primary(.{ .gui = true }, true));
    try std.testing.expect(keys.primary(.{ .gui = true, .shift = true }, true));
    try std.testing.expect(!keys.primary(.{ .ctrl = true }, true));
    try std.testing.expect(!keys.primary(.{}, true));
    try std.testing.expect(keys.primary(.{ .ctrl = true }, false));
    try std.testing.expect(keys.primary(.{ .ctrl = true, .shift = true }, false));
    try std.testing.expect(!keys.primary(.{ .gui = true }, false));
    try std.testing.expect(!keys.primary(.{}, false));
}

test "the two OSes' modifiers together, or Alt, are no shortcut on either" {
    for ([_]bool{ true, false }) |mac| {
        try std.testing.expect(!keys.primary(.{ .ctrl = true, .gui = true }, mac));
        try std.testing.expect(!keys.primary(.{ .ctrl = true, .gui = true, .alt = true }, mac));
        try std.testing.expect(!keys.primary(.{ .gui = true, .alt = true }, mac));
        try std.testing.expect(!keys.primary(.{ .ctrl = true, .alt = true }, mac));
    }
}
