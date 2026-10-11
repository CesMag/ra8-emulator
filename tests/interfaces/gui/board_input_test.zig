//! Host tests for clicks on the board pane's switches (RA8EMU-814): a press
//! released over the same switch is a click, anything else is not, and the
//! held switch draws pressed.
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const pane = gui_app.board_pane;
const input = gui_app.board_input;
const Rect = draw_list.Rect;
const Color = draw_list.Color;

const area: Rect = .{ .x = 0, .y = 0, .w = 480, .h = 320 };

fn middle(rect: Rect) [2]i32 {
    return .{ rect.x + @divTrunc(rect.w, 2), rect.y + @divTrunc(rect.h, 2) };
}

test "a press released over the same switch clicks it" {
    const layout = pane.Layout.of(area);
    for (layout.switches, 0..) |button, index| {
        var press: input.Press = .{};
        const at = middle(button);
        press.down(layout, at[0], at[1]);
        try std.testing.expectEqual(@as(?usize, index), press.held);
        try std.testing.expectEqual(@as(?usize, index), press.up(layout, at[0], at[1]));
        try std.testing.expectEqual(@as(?usize, null), press.held);
    }
}

test "a release off the pressed switch, or a press off every switch, clicks nothing" {
    const layout = pane.Layout.of(area);
    const sw1 = middle(layout.switches[0]);
    const sw2 = middle(layout.switches[1]);
    const panel = middle(layout.panel);
    var press: input.Press = .{};
    press.down(layout, sw1[0], sw1[1]);
    try std.testing.expectEqual(@as(?usize, null), press.up(layout, sw2[0], sw2[1]));
    press.down(layout, sw1[0], sw1[1]);
    try std.testing.expectEqual(@as(?usize, null), press.up(layout, panel[0], panel[1]));
    press.down(layout, panel[0], panel[1]);
    try std.testing.expectEqual(@as(?usize, null), press.held);
    try std.testing.expectEqual(@as(?usize, null), press.up(layout, sw1[0], sw1[1]));
    try std.testing.expectEqual(@as(?usize, null), press.up(layout, sw1[0], sw1[1]));
}

fn faceAt(view: pane.View, button: Rect) !Color {
    var list = draw_list.DrawList.init(std.testing.allocator, area.w, area.h);
    defer list.deinit();
    var frame = try raster.Framebuffer.init(std.testing.allocator, area.w, area.h);
    defer frame.deinit(std.testing.allocator);
    try pane.draw(&list, dark, area, view);
    raster.draw(&frame, &list, font.atlas);
    const at = middle(button);
    return frame.pixels[@intCast(at[1] * area.w + at[0])];
}

test "only the held switch draws pressed" {
    const layout = pane.Layout.of(area);
    const leds: pane.Leds = .{};
    try std.testing.expectEqual(dark.face, try faceAt(.{ .leds = &leds }, layout.switches[0]));
    try std.testing.expectEqual(dark.pressed_face, try faceAt(.{ .leds = &leds, .pressed = 0 }, layout.switches[0]));
    try std.testing.expectEqual(dark.face, try faceAt(.{ .leds = &leds, .pressed = 0 }, layout.switches[1]));
}
