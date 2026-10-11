//! Host tests for the shell's theme (RA8EMU-1165): the choice read from the
//! palette in use, choosing and following the OS, and what a press or a key
//! does to the picker's popover.
const std = @import("std");
const gui_app = @import("gui_app");
const colors = gui_app.colors;
const picker = gui_app.theme_picker;
const strip = gui_app.status_strip;
const Themes = gui_app.shell.theme.Themes;
const dark = &colors.palettes.dark;
const light = &colors.palettes.light;

const width = 480;
const height = 320;
const bar = strip.area(width, height);

/// The middle of the icon button.
const icon_x = picker.button(bar).x + @divFloor(picker.width, 2);
const icon_y = bar.y + @divFloor(bar.h, 2);

fn rowOf(choice: colors.Choice) struct { x: i32, y: i32 } {
    for (picker.rows, 0..) |listed, index| if (listed == choice) {
        const at = picker.row(bar, index);
        return .{ .x = at.x + @divFloor(at.w, 2), .y = at.y + @divFloor(at.h, 2) };
    };
    unreachable;
}

test "the choice is read from the palette in use" {
    var themes: Themes = .{};
    try std.testing.expectEqual(colors.Choice.dark, themes.choice());
    themes.active = light;
    try std.testing.expectEqual(colors.Choice.light, themes.choice());
    themes.follow_os = true;
    try std.testing.expectEqual(colors.Choice.system, themes.choice());
    try std.testing.expectEqual(colors.Choice.system, themes.view().choice);
}

test "choosing pins a palette, and System follows the OS once it is read" {
    var themes: Themes = .{};
    themes.choose(.light);
    try std.testing.expectEqual(light, themes.active);
    try std.testing.expect(!themes.follow_os and !themes.styled);
    themes.choose(.system);
    try std.testing.expect(themes.follow_os and !themes.styled);
    themes.restyle(.dark);
    try std.testing.expect(themes.styled);
    try std.testing.expectEqual(dark, themes.active);
    themes.restyle(.light);
    try std.testing.expectEqual(light, themes.active);
    themes.choose(.system);
    themes.restyle(.unknown);
    try std.testing.expectEqual(light, themes.active);
}

test "a pinned palette ignores the OS" {
    var themes: Themes = .{};
    themes.choose(.dark);
    themes.restyle(.light);
    try std.testing.expect(themes.styled);
    try std.testing.expectEqual(dark, themes.active);
    try std.testing.expectEqual(colors.Choice.dark, themes.choice());
}

test "the icon opens the popover and closes it again" {
    var themes: Themes = .{};
    try std.testing.expect(themes.press(bar, icon_x, icon_y));
    try std.testing.expect(themes.open and themes.view().open);
    try std.testing.expect(themes.press(bar, icon_x, icon_y));
    try std.testing.expect(!themes.open);
    try std.testing.expectEqual(dark, themes.active);
}

test "a row chooses its theme and folds the popover" {
    var themes: Themes = .{};
    for ([_]colors.Choice{ .light, .system, .dark }) |choice| {
        try std.testing.expect(themes.press(bar, icon_x, icon_y));
        const at = rowOf(choice);
        try std.testing.expect(themes.press(bar, at.x, at.y));
        try std.testing.expect(!themes.open);
        try std.testing.expectEqual(choice, themes.choice());
        try std.testing.expect(!themes.styled);
    }
}

test "a row is nothing to press while the popover is folded" {
    var themes: Themes = .{};
    const at = rowOf(.light);
    try std.testing.expect(!themes.press(bar, at.x, at.y));
    try std.testing.expect(!themes.open);
    try std.testing.expectEqual(colors.Choice.dark, themes.choice());
}

test "a press elsewhere folds the popover, is taken, and changes nothing" {
    var themes: Themes = .{};
    themes.styled = true;
    try std.testing.expect(themes.press(bar, icon_x, icon_y));
    try std.testing.expect(themes.press(bar, 10, 10));
    try std.testing.expect(!themes.open);
    try std.testing.expectEqual(dark, themes.active);
    try std.testing.expect(themes.styled and !themes.follow_os);
    try std.testing.expect(!themes.press(bar, 10, 10));
}

test "Escape folds the popover and changes nothing; other keys pass" {
    const escape: gui_app.platform.Event = .{ .key = .{ .code = 0x1B, .down = true } };
    var themes: Themes = .{};
    try std.testing.expect(!themes.key(escape));
    try std.testing.expect(themes.press(bar, icon_x, icon_y));
    try std.testing.expect(!themes.key(.{ .key = .{ .code = 'a', .down = true } }));
    try std.testing.expect(!themes.key(.{ .key = .{ .code = 0x1B, .down = false } }));
    try std.testing.expect(!themes.key(.{ .text = gui_app.platform.Text.of("x") }));
    try std.testing.expect(themes.open);
    try std.testing.expect(themes.key(escape));
    try std.testing.expect(!themes.open);
    try std.testing.expectEqual(colors.Choice.dark, themes.choice());
}
