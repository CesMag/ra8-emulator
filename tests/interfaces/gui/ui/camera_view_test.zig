//! Covers src/interfaces/gui/ui/camera_view.zig: what the camera panel draws through the
//! CPU rasterizer, and how clicks on it pick sources and answer the webcam
//! dialog.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const view = gui_app.camera_view;
const Panel = gui_app.camera_panel.Panel;
const Rect = draw_list.Rect;

const layout = view.Layout{ .x = 10, .y = 20 };

/// A corner just inside a button: its colour, clear of the centred label.
fn centre(at: Rect) [2]i32 {
    return .{ at.x + 1, at.y + 1 };
}

fn inked(frame: *const raster.Framebuffer, at: Rect, ink: draw_list.Color) usize {
    var count: usize = 0;
    var y = at.y;
    while (y < at.y + at.h) : (y += 1) {
        var x = at.x;
        while (x < at.x + at.w) : (x += 1) {
            if (std.meta.eql(frame.at(@intCast(x), @intCast(y)), ink)) count += 1;
        }
    }
    return count;
}

fn render(panel: Panel) !raster.Framebuffer {
    var list = draw_list.DrawList.init(std.testing.allocator, 256, 128);
    defer list.deinit();
    try view.draw(&list, layout, panel);
    var frame = try raster.Framebuffer.init(std.testing.allocator, 256, 128);
    raster.draw(&frame, &list, ra8.render.font.atlas);
    return frame;
}

fn pixel(frame: *const raster.Framebuffer, at: Rect) draw_list.Color {
    const c = centre(at);
    return frame.at(@intCast(c[0]), @intCast(c[1]));
}

test "every source has its button and the active one is ringed" {
    var frame = try render(.{});
    defer frame.deinit(std.testing.allocator);
    for (std.enums.values(gui_app.camera_panel.Kind)) |kind| {
        try std.testing.expectEqual(view.colorOf(kind), pixel(&frame, layout.source(kind)));
    }
    const gradient = layout.source(.gradient);
    try std.testing.expectEqual(view.ring, frame.at(@intCast(gradient.x - 1), @intCast(gradient.y)));
    const image = layout.source(.image);
    try std.testing.expectEqual(view.background, frame.at(@intCast(image.x - 1), @intCast(image.y)));
}

test "the dot is red only while the webcam is the source" {
    var panel = Panel{};
    var off = try render(panel);
    defer off.deinit(std.testing.allocator);
    try std.testing.expectEqual(view.camera_off, pixel(&off, layout.indicator()));
    panel.pick(.webcam);
    panel.answer(.allow_once);
    var on = try render(panel);
    defer on.deinit(std.testing.allocator);
    try std.testing.expectEqual(view.camera_on, pixel(&on, layout.indicator()));
}

test "the dialog shows only while the webcam is being asked" {
    var panel = Panel{};
    var closed = try render(panel);
    defer closed.deinit(std.testing.allocator);
    try std.testing.expectEqual(view.background, pixel(&closed, layout.dialog(.always)));
    panel.pick(.webcam);
    var open = try render(panel);
    defer open.deinit(std.testing.allocator);
    try std.testing.expectEqual(view.answerColor(.always), pixel(&open, layout.dialog(.always)));
}

test "clicking a source picks it" {
    var panel = Panel{};
    const c = centre(layout.source(.video));
    try std.testing.expect(view.click(&panel, layout, c[0], c[1]));
    try std.testing.expectEqual(.video, panel.active);
}

test "the webcam goes live only through the dialog" {
    var panel = Panel{};
    const cam = centre(layout.source(.webcam));
    try std.testing.expect(view.click(&panel, layout, cam[0], cam[1]));
    try std.testing.expect(panel.asking);
    try std.testing.expect(!panel.cameraOn());
    const cancel = centre(layout.dialog(.cancel));
    try std.testing.expect(view.click(&panel, layout, cancel[0], cancel[1]));
    try std.testing.expect(!panel.cameraOn());
    _ = view.click(&panel, layout, cam[0], cam[1]);
    const once = centre(layout.dialog(.allow_once));
    try std.testing.expect(view.click(&panel, layout, once[0], once[1]));
    try std.testing.expect(panel.cameraOn());
}

test "the dialog row does nothing while closed and clicks outside are not taken" {
    var panel = Panel{};
    const once = centre(layout.dialog(.allow_once));
    try std.testing.expect(view.click(&panel, layout, once[0], once[1]));
    try std.testing.expectEqual(.gradient, panel.active);
    try std.testing.expect(!view.click(&panel, layout, 0, 0));
    try std.testing.expect(!view.click(&panel, layout, 250, 120));
}

test "every source and dialog button carries a label in ink that reads on it" {
    var frame = try render(.{ .asking = true });
    defer frame.deinit(std.testing.allocator);
    for (std.enums.values(gui_app.camera_panel.Kind)) |kind| {
        const ink = view.inkOn(view.colorOf(kind));
        try std.testing.expect(!std.meta.eql(ink, view.colorOf(kind)));
        try std.testing.expect(inked(&frame, layout.source(kind), ink) > 10);
        try std.testing.expect(view.labelOf(kind).len <= 3);
    }
    for (std.enums.values(gui_app.camera_panel.Answer)) |reply| {
        try std.testing.expect(inked(&frame, layout.dialog(reply), view.inkOn(view.answerColor(reply))) > 5);
    }
}

test "label ink is dark on light fills and light on dark ones" {
    try std.testing.expectEqual(view.background, view.inkOn(draw_list.Color.rgb(0xEB, 0xCB, 0x8B)));
    try std.testing.expectEqual(view.ring, view.inkOn(view.camera_off));
}
