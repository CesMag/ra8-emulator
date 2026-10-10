//! Host tests for the board pane (RA8EMU-813): where the board, panel, LEDs
//! and switches sit at two sizes, a too-small area that draws nothing, LED
//! state folded from session events, switch hits, and a pinned CPU-backend
//! golden with LED1 on and the others off.
const std = @import("std");
const ra8 = @import("ra8");
const draw_list = ra8.gui.draw_list;
const raster = ra8.gui.raster;
const font = ra8.gui.font;
const pane = ra8.gui.board_pane;
const capture = ra8.gui.board_capture;
const proto = ra8.interfaces.rpc.session;
const Rect = draw_list.Rect;
const Color = draw_list.Color;

fn inside(outer: Rect, inner: Rect) bool {
    return inner.x >= outer.x and inner.y >= outer.y and inner.x + inner.w <= outer.x + outer.w and inner.y + inner.h <= outer.y + outer.h;
}

fn overlap(a: Rect, b: Rect) bool {
    return !a.intersect(b).empty();
}

fn checkLayout(area: Rect) !void {
    const layout = pane.Layout.of(area);
    try std.testing.expect(!layout.board.empty());
    try std.testing.expect(inside(area, layout.board));
    try std.testing.expectEqual(@as(i64, layout.board.w) * 2, @as(i64, layout.board.h) * 3);
    try std.testing.expect(inside(layout.board, layout.panel));
    for (layout.leds) |led| {
        try std.testing.expect(!led.empty() and inside(layout.board, led) and !overlap(led, layout.panel));
    }
    for (layout.switches, 0..) |button, index| {
        try std.testing.expect(!button.empty() and inside(layout.board, button) and !overlap(button, layout.panel));
        for (layout.leds) |led| try std.testing.expect(!overlap(button, led));
        try std.testing.expectEqual(@as(?usize, index), layout.hit(button.x + 1, button.y + 1));
    }
    try std.testing.expect(layout.leds[0].y < layout.leds[1].y and layout.leds[1].y < layout.leds[2].y);
    try std.testing.expect(layout.switches[0].y < layout.switches[1].y);
    try std.testing.expectEqual(@as(?usize, null), layout.hit(layout.panel.x + 1, layout.panel.y + 1));
}

test "the board keeps its shape and every part sits inside it at two sizes" {
    try checkLayout(.{ .x = 0, .y = 0, .w = 480, .h = 320 });
    try checkLayout(.{ .x = 10, .y = 20, .w = 900, .h = 400 });
}

test "an area under the minimum lays out nothing and draws nothing" {
    const area: Rect = .{ .x = 0, .y = 0, .w = pane.min_w - 1, .h = 200 };
    const layout = pane.Layout.of(area);
    try std.testing.expect(layout.board.empty() and layout.panel.empty());
    var list = draw_list.DrawList.init(std.testing.allocator, 200, 200);
    defer list.deinit();
    const leds: pane.Leds = .{};
    try pane.draw(&list, area, .{ .leds = &leds });
    try std.testing.expectEqual(@as(usize, 0), list.commands.items.len);
}

test "LEDs follow led_changed events and ignore everything else" {
    var leds: pane.Leds = .{};
    capture.observe(&leds, .{ .core = .cpu0, .kind = .led_changed, .address = 0x100 });
    capture.observe(&leds, .{ .core = .cpu0, .kind = .led_changed, .address = 0x102 });
    capture.observe(&leds, .{ .core = .cpu0, .kind = .led_changed, .address = 0x002 });
    capture.observe(&leds, .{ .core = .cpu0, .kind = .led_changed, .address = 0x107 });
    capture.observe(&leds, .{ .core = .cpu0, .kind = .breakpoint_set, .address = 0x101 });
    try std.testing.expectEqualSlices(bool, &.{ true, false, false }, &leds.on);
}

test "a lit LED takes the board's colour" {
    try std.testing.expectEqual(Color.rgb(0, 0, 0xFF), pane.lampOf(0x001F));
    try std.testing.expectEqual(Color.rgb(0, 0xFF, 0), pane.lampOf(0x07E0));
    try std.testing.expectEqual(Color.rgb(0xFF, 0, 0), pane.lampOf(0xF800));
}

test "the board pane frame with LED1 on is pinned" {
    const w = 480;
    const h = 320;
    var list = draw_list.DrawList.init(std.testing.allocator, w, h);
    defer list.deinit();
    var frame = try raster.Framebuffer.init(std.testing.allocator, w, h);
    defer frame.deinit(std.testing.allocator);
    var pixels: [64 * 36]Color = undefined;
    for (&pixels, 0..) |*pixel, index| {
        const shade: u8 = @intCast((index % 64) * 4);
        pixel.* = Color.rgb(shade, shade, shade);
    }
    var leds: pane.Leds = .{};
    capture.observe(&leds, .{ .core = .cpu0, .kind = .led_changed, .address = 0x100 });
    try pane.draw(&list, .{ .x = 0, .y = 0, .w = w, .h = h }, .{ .leds = &leds, .panel = .{ .width = 64, .height = 36, .pixels = &pixels } });
    raster.draw(&frame, &list, font.atlas);
    const digest = std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(frame.pixels));
    try std.testing.expectEqual(@as(u64, 11290556999026159831), digest);
}

test "the pane's LED count and lamp colours are the chip's" {
    const gpio = ra8.periph.gpio;
    try std.testing.expectEqual(gpio.led_count, pane.led_count);
    for (gpio.leds, pane.led_rgb565) |led, rgb565| try std.testing.expectEqual(led.rgb565, rgb565);
}
