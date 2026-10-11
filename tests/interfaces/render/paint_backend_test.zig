//! Covers src/interfaces/render/paint_backend.zig: the shared ra8_widget
//! Paint table (RA8FW-951) bound to the emulator's CPU rasterizer. Every
//! member is bound, fills respect the clip stack, alpha blends source-over,
//! lines include both end points, blits read ra8_gfx's formats, and text
//! lands inside the measured extent.
const std = @import("std");
const ra8 = @import("ra8");
const raster = ra8.render.raster;
const backend_mod = ra8.render.paint_backend;
const draw_list = ra8.render.draw_list;

const Rect = draw_list.Rect;

const Surface = struct {
    fb: *raster.Framebuffer,
    backend: backend_mod.Backend,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Surface {
        const fb = try allocator.create(raster.Framebuffer);
        errdefer allocator.destroy(fb);
        fb.* = try raster.Framebuffer.init(allocator, width, height);
        @memset(fb.pixels, draw_list.Color.rgb(0, 0, 0));
        return .{ .fb = fb, .backend = backend_mod.Backend.init(fb), .allocator = allocator };
    }

    fn deinit(self: *Surface) void {
        self.fb.deinit(self.allocator);
        self.allocator.destroy(self.fb);
        self.backend.deinit();
    }
};

const Frame = struct {
    surface: *Surface,
    paint: @TypeOf(@as(*backend_mod.Backend, undefined).paint()),
};

fn frame(s: *Surface) Frame {
    return .{ .surface = s, .paint = s.backend.paint() };
}

fn put(paint: anytype, x: i32, y: i32, w: i32, h: i32, color: u32) void {
    paint.fill_rect.?(paint.user, x, y, w, h, color);
}

test "the paint table binds every member" {
    var s = try Surface.init(std.testing.allocator, 64, 48);
    defer s.deinit();
    const f = frame(&s);
    try std.testing.expect(f.paint.fill_rect != null);
    try std.testing.expect(f.paint.draw_text != null);
    try std.testing.expect(f.paint.text_size != null);
    try std.testing.expect(f.paint.draw_text_face != null);
    try std.testing.expect(f.paint.text_size_face != null);
    try std.testing.expect(f.paint.draw_text_style != null);
    try std.testing.expect(f.paint.text_size_style != null);
    try std.testing.expect(f.paint.draw_line != null);
    try std.testing.expect(f.paint.blit != null);
    try std.testing.expect(f.paint.push_clip != null);
    try std.testing.expect(f.paint.pop_clip != null);
    try std.testing.expect(f.paint.fill_rect_alpha != null);
}

test "fill_rect paints inside the clip stack and the pop restores it" {
    var s = try Surface.init(std.testing.allocator, 32, 32);
    defer s.deinit();
    const f = frame(&s);
    put(f.paint, 0, 0, 32, 32, 0x101010);
    f.paint.push_clip.?(f.paint.user, 4, 4, 8, 8);
    put(f.paint, 0, 0, 32, 32, 0xFF0000);
    try std.testing.expectEqual(draw_list.Color.rgb(0xFF, 0, 0), s.fb.at(7, 7));
    try std.testing.expectEqual(draw_list.Color.rgb(0x10, 0x10, 0x10), s.fb.at(12, 12));
    f.paint.pop_clip.?(f.paint.user);
    put(f.paint, 8, 8, 4, 4, 0xFF0000);
    try std.testing.expectEqual(draw_list.Color.rgb(0xFF, 0, 0), s.fb.at(9, 9));
}

test "fill_rect_alpha blends source-over and zero alpha paints nothing" {
    var s = try Surface.init(std.testing.allocator, 8, 8);
    defer s.deinit();
    const f = frame(&s);
    put(f.paint, 0, 0, 8, 8, 0x000000);
    f.paint.fill_rect_alpha.?(f.paint.user, 0, 0, 4, 4, 0xFFFFFF, 128);
    const mixed = s.fb.at(1, 1);
    try std.testing.expect(mixed.r > 120 and mixed.r < 140);
    try std.testing.expectEqual(mixed.r, mixed.g);
    f.paint.fill_rect_alpha.?(f.paint.user, 4, 4, 4, 4, 0xFFFFFF, 0);
    try std.testing.expectEqual(draw_list.Color.rgb(0, 0, 0), s.fb.at(5, 5));
}

test "draw_line includes both end points and respects the clip" {
    var s = try Surface.init(std.testing.allocator, 32, 32);
    defer s.deinit();
    const f = frame(&s);
    f.paint.draw_line.?(f.paint.user, 2, 2, 10, 10, 0x00FF00);
    try std.testing.expectEqual(draw_list.Color.rgb(0, 0xFF, 0), s.fb.at(2, 2));
    try std.testing.expectEqual(draw_list.Color.rgb(0, 0xFF, 0), s.fb.at(10, 10));
    f.paint.push_clip.?(f.paint.user, 0, 0, 4, 4);
    f.paint.draw_line.?(f.paint.user, 8, 8, 20, 20, 0x00FF00);
    try std.testing.expectEqual(draw_list.Color.rgb(0, 0xFF, 0), s.fb.at(8, 8));
    try std.testing.expectEqual(draw_list.Color.rgb(0, 0, 0), s.fb.at(20, 20));
}

test "blit reads gray8 and clips past the surface edge" {
    var s = try Surface.init(std.testing.allocator, 8, 8);
    defer s.deinit();
    const f = frame(&s);
    const pixels = [_]u8{ 0x40, 0x80, 0xC0, 0xFF };
    f.paint.blit.?(f.paint.user, 2, 2, 2, 2, &pixels, 2, @backingInt(backend_mod.Format.gray8));
    try std.testing.expectEqual(draw_list.Color.rgb(0x80, 0x80, 0x80), s.fb.at(3, 2));
    try std.testing.expectEqual(draw_list.Color.rgb(0xFF, 0xFF, 0xFF), s.fb.at(3, 3));
    f.paint.blit.?(f.paint.user, 6, 6, 8, 8, &pixels, 2, @backingInt(backend_mod.Format.gray8));
    try std.testing.expectEqual(draw_list.Color.rgb(0x80, 0x80, 0x80), s.fb.at(7, 6));
    try std.testing.expectEqual(draw_list.Color.rgb(0xFF, 0xFF, 0xFF), s.fb.at(7, 7));
}

test "draw_text lands inside the measured extent" {
    var s = try Surface.init(std.testing.allocator, 64, 32);
    defer s.deinit();
    const f = frame(&s);
    var buf = [_:0]u8{ 'A', 0 };
    f.paint.draw_text.?(f.paint.user, 8, 8, &buf, 0xFFFFFF, 0x000000);
    var lit: usize = 0;
    var y: u32 = 8;
    while (y < 8 + ra8.render.font.glyph_h) : (y += 1) {
        var x: u32 = 8;
        while (x < 8 + ra8.render.font.glyph_w) : (x += 1) {
            if (s.fb.at(x, y).r != 0) lit += 1;
        }
    }
    try std.testing.expect(lit > 0);
    var w: i32 = 0;
    var h: i32 = 0;
    f.paint.text_size.?(f.paint.user, &buf, &w, &h);
    try std.testing.expect(w > 0 and h > 0);
}
