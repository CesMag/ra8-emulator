const std = @import("std");
const ra8 = @import("ra8");
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const Color = draw_list.Color;

const clear = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
const red = Color.rgb(255, 0, 0);
const blue = Color.rgb(0, 0, 255);

const Scene = struct {
    list: draw_list.DrawList,
    frame: raster.Framebuffer,

    fn init(width: u32, height: u32) !Scene {
        return .{
            .list = draw_list.DrawList.init(std.testing.allocator, width, height),
            .frame = try raster.Framebuffer.init(std.testing.allocator, width, height),
        };
    }

    fn deinit(self: *Scene) void {
        self.list.deinit();
        self.frame.deinit(std.testing.allocator);
    }

    fn draw(self: *Scene, atlas: ?raster.Atlas) void {
        raster.draw(&self.frame, &self.list, atlas);
    }

    /// How many pixels of the frame are `color`.
    fn count(self: *const Scene, color: Color) usize {
        var n: usize = 0;
        for (self.frame.pixels) |pixel| {
            if (std.meta.eql(pixel, color)) n += 1;
        }
        return n;
    }
};

test "a fill covers exactly its area" {
    var scene = try Scene.init(8, 8);
    defer scene.deinit();
    try scene.list.fill(.{ .x = 2, .y = 3, .w = 3, .h = 2 }, red);
    scene.draw(null);
    try std.testing.expectEqual(@as(usize, 6), scene.count(red));
    try std.testing.expectEqual(red, scene.frame.at(2, 3));
    try std.testing.expectEqual(red, scene.frame.at(4, 4));
    try std.testing.expectEqual(clear, scene.frame.at(5, 4));
    try std.testing.expectEqual(clear, scene.frame.at(2, 5));
}

test "a fill is cut to its clip and to the frame" {
    var scene = try Scene.init(8, 8);
    defer scene.deinit();
    try scene.list.fill(.{ .x = -4, .y = -4, .w = 20, .h = 20 }, blue);
    try scene.list.pushClip(.{ .x = 1, .y = 1, .w = 2, .h = 2 });
    try scene.list.fill(.{ .x = 0, .y = 0, .w = 8, .h = 8 }, red);
    scene.list.popClip();
    scene.draw(null);
    try std.testing.expectEqual(@as(usize, 4), scene.count(red));
    try std.testing.expectEqual(@as(usize, 60), scene.count(blue));
}

test "half-transparent red over blue blends source-over, rounded" {
    var scene = try Scene.init(1, 1);
    defer scene.deinit();
    try scene.list.fill(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, blue);
    try scene.list.fill(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{ .r = 255, .g = 0, .b = 0, .a = 128 });
    scene.draw(null);
    try std.testing.expectEqual(Color{ .r = 128, .g = 0, .b = 127, .a = 255 }, scene.frame.at(0, 0));
}

test "lines include both ends and follow Bresenham" {
    var scene = try Scene.init(8, 8);
    defer scene.deinit();
    try scene.list.line(1, 1, 6, 1, red);
    try scene.list.line(0, 7, 3, 4, blue);
    scene.draw(null);
    try std.testing.expectEqual(@as(usize, 6), scene.count(red));
    try std.testing.expectEqual(@as(usize, 4), scene.count(blue));
    for ([_]u32{ 0, 1, 2, 3 }) |i| try std.testing.expectEqual(blue, scene.frame.at(i, 7 - i));
}

test "a line is cut to its clip" {
    var scene = try Scene.init(8, 8);
    defer scene.deinit();
    try scene.list.pushClip(.{ .x = 2, .y = 0, .w = 3, .h = 8 });
    try scene.list.line(0, 2, 7, 2, red);
    scene.list.popClip();
    scene.draw(null);
    try std.testing.expectEqual(@as(usize, 3), scene.count(red));
    try std.testing.expectEqual(clear, scene.frame.at(1, 2));
    try std.testing.expectEqual(red, scene.frame.at(4, 2));
}

test "an image quad scales nearest-neighbour into its area" {
    var scene = try Scene.init(4, 4);
    defer scene.deinit();
    const pixels = [_]Color{ red, blue, blue, red };
    try scene.list.image(.{ .x = 0, .y = 0, .w = 4, .h = 4 }, .{ .width = 2, .height = 2, .pixels = &pixels });
    scene.draw(null);
    try std.testing.expectEqual(red, scene.frame.at(1, 1));
    try std.testing.expectEqual(blue, scene.frame.at(2, 1));
    try std.testing.expectEqual(blue, scene.frame.at(1, 2));
    try std.testing.expectEqual(red, scene.frame.at(3, 3));
    try std.testing.expectEqual(@as(usize, 8), scene.count(red));
}

test "a glyph's coverage scales its colour's alpha" {
    var scene = try Scene.init(3, 1);
    defer scene.deinit();
    try scene.list.fill(.{ .x = 0, .y = 0, .w = 3, .h = 1 }, blue);
    // Atlas row 1 holds the glyph: full, none, half.
    const coverage = [_]u8{ 9, 9, 9, 255, 0, 128 };
    const atlas: raster.Atlas = .{ .width = 3, .height = 2, .coverage = &coverage };
    try scene.list.glyph(.{ .x = 0, .y = 0, .w = 3, .h = 1 }, 0, 1, red);
    scene.draw(atlas);
    try std.testing.expectEqual(red, scene.frame.at(0, 0));
    try std.testing.expectEqual(blue, scene.frame.at(1, 0));
    try std.testing.expectEqual(Color{ .r = 128, .g = 0, .b = 127, .a = 255 }, scene.frame.at(2, 0));
}

test "glyphs draw nothing without an atlas" {
    var scene = try Scene.init(2, 2);
    defer scene.deinit();
    try scene.list.glyph(.{ .x = 0, .y = 0, .w = 2, .h = 2 }, 0, 0, red);
    scene.draw(null);
    try std.testing.expectEqual(@as(usize, 4), scene.count(clear));
}

test "a smooth image blends between source pixels and a nearest one does not" {
    const black = Color.rgb(0, 0, 0);
    const white = Color.rgb(255, 255, 255);
    const source: draw_list.Image = .{ .width = 2, .height = 1, .pixels = &.{ black, white } };
    var nearest = try Scene.init(8, 1);
    defer nearest.deinit();
    try nearest.list.image(.{ .x = 0, .y = 0, .w = 8, .h = 1 }, source);
    nearest.draw(null);
    try std.testing.expectEqual(@as(usize, 4), nearest.count(black));
    try std.testing.expectEqual(@as(usize, 4), nearest.count(white));
    var smooth = try Scene.init(8, 1);
    defer smooth.deinit();
    try smooth.list.scaledImage(.{ .x = 0, .y = 0, .w = 8, .h = 1 }, source, true);
    smooth.draw(null);
    try std.testing.expectEqual(black, smooth.frame.at(0, 0));
    try std.testing.expectEqual(white, smooth.frame.at(7, 0));
    var last: u8 = 0;
    for (0..8) |x| {
        const shade = smooth.frame.at(@intCast(x), 0).r;
        try std.testing.expect(shade >= last);
        last = shade;
    }
    try std.testing.expect(smooth.count(black) + smooth.count(white) < 8);
}

test "a smooth image at its own size copies its pixels" {
    const source: draw_list.Image = .{ .width = 2, .height = 1, .pixels = &.{ red, blue } };
    var scene = try Scene.init(2, 1);
    defer scene.deinit();
    try scene.list.scaledImage(.{ .x = 0, .y = 0, .w = 2, .h = 1 }, source, true);
    scene.draw(null);
    try std.testing.expectEqual(red, scene.frame.at(0, 0));
    try std.testing.expectEqual(blue, scene.frame.at(1, 0));
}
