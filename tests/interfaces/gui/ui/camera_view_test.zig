//! Covers src/interfaces/gui/ui/camera_view.zig: what the camera panel draws through the
//! CPU rasterizer, and how clicks on it pick sources and answer the webcam
//! dialog.
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const light = &@import("gui_app").colors.palettes.light;
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
    return renderIn(dark, panel);
}

fn renderIn(theme: *const gui_app.colors.Theme, panel: Panel) !raster.Framebuffer {
    var list = draw_list.DrawList.init(std.testing.allocator, 256, 128);
    defer list.deinit();
    try view.draw(&list, theme, layout, panel);
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
        try std.testing.expectEqual(view.colorOf(dark, kind), pixel(&frame, layout.source(kind)));
    }
    const gradient = layout.source(.gradient);
    try std.testing.expectEqual(dark.ink, frame.at(@intCast(gradient.x - 1), @intCast(gradient.y)));
    const image = layout.source(.image);
    try std.testing.expectEqual(dark.preview, frame.at(@intCast(image.x - 1), @intCast(image.y)));
}

test "the dot is red only while the webcam is the source" {
    var panel = Panel{};
    var off = try render(panel);
    defer off.deinit(std.testing.allocator);
    try std.testing.expectEqual(dark.border, pixel(&off, layout.indicator()));
    panel.pick(.webcam);
    panel.answer(.allow_once);
    var on = try render(panel);
    defer on.deinit(std.testing.allocator);
    try std.testing.expectEqual(dark.recording, pixel(&on, layout.indicator()));
}

test "the dialog shows only while the webcam is being asked" {
    var panel = Panel{};
    var closed = try render(panel);
    defer closed.deinit(std.testing.allocator);
    try std.testing.expectEqual(dark.preview, pixel(&closed, layout.dialog(.always)));
    panel.pick(.webcam);
    var open = try render(panel);
    defer open.deinit(std.testing.allocator);
    try std.testing.expectEqual(view.answerColor(dark, .always), pixel(&open, layout.dialog(.always)));
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

test "while Always stands its button shows, whole and clear of the dialog's three" {
    var plain = try render(.{});
    defer plain.deinit(std.testing.allocator);
    const at = layout.withdraw();
    try std.testing.expectEqual(dark.preview, pixel(&plain, at));
    var standing = try render(.{ .always = true });
    defer standing.deinit(std.testing.allocator);
    try std.testing.expectEqual(dark.hue.blue, pixel(&standing, at));
    try std.testing.expect(inked(&standing, at, view.inkOn(dark, dark.hue.blue)) > 40);
    try std.testing.expect(ra8.render.font.textWidth(view.withdraw_label.len) <= at.w - 2);
    for (std.enums.values(gui_app.camera_panel.Answer)) |reply| {
        const answer = layout.dialog(reply);
        try std.testing.expect(at.x >= answer.x + answer.w);
        try std.testing.expectEqual(answer.y, at.y);
    }
    const area = layout.area();
    try std.testing.expect(at.x + at.w <= area.x + area.w and at.y + at.h <= area.y + area.h);
}

test "a click on the button takes Always back, and only while it stands" {
    var panel = Panel{};
    const c = centre(layout.withdraw());
    try std.testing.expect(view.click(&panel, layout, c[0], c[1]));
    try std.testing.expect(!panel.always);
    panel.pick(.webcam);
    panel.answer(.always);
    try std.testing.expect(view.click(&panel, layout, c[0], c[1]));
    try std.testing.expect(!panel.always);
    try std.testing.expect(panel.cameraOn());
    panel.pick(.gradient);
    panel.pick(.webcam);
    try std.testing.expect(panel.asking);
}

test "a second click where Always was answered does not take it back" {
    var panel = Panel{};
    panel.pick(.webcam);
    const c = centre(layout.dialog(.always));
    try std.testing.expect(view.click(&panel, layout, c[0], c[1]));
    try std.testing.expect(view.click(&panel, layout, c[0], c[1]));
    try std.testing.expect(panel.always);
    try std.testing.expect(panel.cameraOn());
}

test "every source and dialog button carries a label in ink that reads on it" {
    var frame = try render(.{ .asking = true });
    defer frame.deinit(std.testing.allocator);
    for (std.enums.values(gui_app.camera_panel.Kind)) |kind| {
        const ink = view.inkOn(dark, view.colorOf(dark, kind));
        try std.testing.expect(!std.meta.eql(ink, view.colorOf(dark, kind)));
        try std.testing.expect(inked(&frame, layout.source(kind), ink) > 10);
        try std.testing.expect(view.labelOf(kind).len <= 3);
    }
    for (std.enums.values(gui_app.camera_panel.Answer)) |reply| {
        try std.testing.expect(inked(&frame, layout.dialog(reply), view.inkOn(dark, view.answerColor(dark, reply))) > 5);
    }
}

test "label ink is dark on light fills and light on dark ones" {
    try std.testing.expectEqual(dark.preview, view.inkOn(dark, draw_list.Color.rgb(0xEB, 0xCB, 0x8B)));
    try std.testing.expectEqual(dark.ink, view.inkOn(dark, dark.border));
}

test "the panel, asking about the webcam, rasterises to a pinned golden in each palette" {
    const asking: Panel = .{ .active = .webcam, .asking = true };
    var dark_frame = try renderIn(dark, asking);
    defer dark_frame.deinit(std.testing.allocator);
    var light_frame = try renderIn(light, asking);
    defer light_frame.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 14812365515339288380), std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(dark_frame.pixels)));
    try std.testing.expectEqual(@as(u64, 15016311228300023527), std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(light_frame.pixels)));
}
