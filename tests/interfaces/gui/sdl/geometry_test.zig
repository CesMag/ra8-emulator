//! The geometry presenter against the CPU golden (RA8EMU-733). One scene
//! goes through raster.draw and through sdl.geometry on SDL's software
//! renderer into an offscreen surface; both are read back and compared.
//! Tolerance: opaque scenes match exactly; translucent fills and lines are
//! within 1 per channel. Translucent glyphs and texels are within 2: SDL's
//! software blitter blends a texture as two truncating x*y/255 steps
//! (MULT_DIV_255 in src/video/SDL_blit.h) where raster.blend rounds once.
//!
//! Textures here are uniform. SDL's software rasterizer maps texture
//! coordinates to integer texel corners and pulls the far edge in by one
//! texel (src/render/software/SDL_triangle.c), so it cannot stand in for a
//! GPU's nearest sampling at pixel centres. Which texel each pixel reads is
//! proven in geometry_test.zig; this file proves the uploads, the coverage
//! in alpha, the colour modulation, the per-run clips and the blending.
//! Built only by `zig build gui-test -Dgui`.
const std = @import("std");
const ra8 = @import("ra8");
const sdl = @import("gui_sdl");

const c = sdl.c;
const render = ra8.render;
const draw_list = render.draw_list;
const raster = render.raster;
const Color = draw_list.Color;
const Rect = draw_list.Rect;

const width = 48;
const height = 32;

const Scene = struct {
    /// Alpha of the overlay fills.
    tint: u8,
    /// Glyphs and images drawn too, with every texel this colour and
    /// every atlas cell this coverage.
    textured: bool = false,
    texel: Color = Color.rgb(9, 99, 199),
    coverage: u8 = 255,
};

fn rect(x: i32, y: i32, w: i32, h: i32) Rect {
    return .{ .x = x, .y = y, .w = w, .h = h };
}

/// Fills, lines in four directions and, when textured, glyphs and an
/// image at 1:1, 2x and 3x3.5 scale, under two nested clips.
fn scene(list: *draw_list.DrawList, s: Scene, texels: []const Color) !void {
    const picture = draw_list.Image{ .width = 3, .height = 2, .pixels = texels };
    try list.fill(rect(0, 0, width, height), Color.rgb(30, 34, 40));
    try list.fill(rect(2, 2, 20, 10), .{ .r = 200, .g = 40, .b = 40, .a = s.tint });
    try list.line(0, 31, 47, 0, Color.rgb(250, 250, 0));
    try list.line(5, 20, 30, 20, Color.rgb(0, 200, 255));
    try list.line(40, 28, 40, 2, Color.rgb(255, 255, 255));
    try list.line(44, 30, 26, 3, Color.rgb(120, 255, 120));
    try list.pushClip(rect(8, 8, 24, 16));
    try list.pushClip(rect(16, 4, 30, 10));
    try list.fill(rect(0, 0, width, height), .{ .r = 40, .g = 80, .b = 160, .a = s.tint });
    if (s.textured) try list.glyph(rect(18, 6, 4, 4), 0, 0, Color.rgb(255, 255, 255));
    list.popClip();
    if (s.textured) try list.image(rect(10, 14, 6, 4), picture);
    if (s.textured) try list.glyph(rect(28, 18, 4, 4), 0, 0, Color.rgb(255, 128, 0));
    list.popClip();
    if (!s.textured) return;
    try list.image(rect(34, 20, 3, 2), picture);
    try list.image(rect(1, 24, 9, 7), picture);
}

fn golden(list: *const draw_list.DrawList, atlas: raster.Atlas) !raster.Framebuffer {
    var frame = try raster.Framebuffer.init(std.testing.allocator, width, height);
    raster.draw(&frame, list, atlas);
    return frame;
}

/// The same list through the geometry presenter, read back as RGBA32.
fn throughSdl(list: *const draw_list.DrawList, atlas: raster.Atlas, out: []Color) !void {
    const surface = c.SDL_CreateSurface(width, height, c.SDL_PIXELFORMAT_RGBA32) orelse return error.SdlSurface;
    defer c.SDL_DestroySurface(surface);
    const renderer = c.SDL_CreateSoftwareRenderer(surface) orelse return error.SdlRenderer;
    defer c.SDL_DestroyRenderer(renderer);
    _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 0);
    _ = c.SDL_RenderClear(renderer);
    var textures = sdl.geometry.Textures.init(std.testing.allocator, renderer);
    defer textures.deinit();
    try textures.setAtlas(atlas);
    var batch = render.geometry.Batch.init(std.testing.allocator);
    defer batch.deinit();
    try batch.build(list, atlas);
    try textures.beginFrame();
    try sdl.geometry.draw(renderer, &textures, &batch);
    const read = c.SDL_RenderReadPixels(renderer, null) orelse return error.SdlRead;
    defer c.SDL_DestroySurface(read);
    const rgba = c.SDL_ConvertSurface(read, c.SDL_PIXELFORMAT_RGBA32) orelse return error.SdlConvert;
    defer c.SDL_DestroySurface(rgba);
    const bytes: [*]const u8 = @ptrCast(rgba.*.pixels.?);
    const pitch: usize = @intCast(rgba.*.pitch);
    for (0..height) |y| {
        const row: [*]const Color = @ptrCast(@alignCast(bytes + y * pitch));
        @memcpy(out[y * width ..][0..width], row[0..width]);
    }
}

/// The largest per-channel difference over the frame, after printing the
/// first few differing pixels so a failure says where.
fn worst(want: []const Color, got: []const Color) u8 {
    var max: u8 = 0;
    var shown: usize = 0;
    for (want, got, 0..) |w, g, i| {
        const d = @max(@max(diff(w.r, g.r), diff(w.g, g.g)), @max(diff(w.b, g.b), diff(w.a, g.a)));
        if (d > 0 and shown < 8) {
            std.debug.print("({d},{d}) want {any} got {any}\n", .{ i % width, i / width, w, g });
            shown += 1;
        }
        max = @max(max, d);
    }
    return max;
}

fn diff(a: u8, b: u8) u8 {
    return if (a > b) a - b else b - a;
}

fn compare(s: Scene) !u8 {
    var list = draw_list.DrawList.init(std.testing.allocator, width, height);
    defer list.deinit();
    const texels = @as([6]Color, @splat(s.texel));
    try scene(&list, s, &texels);
    const coverage = @as([16]u8, @splat(s.coverage));
    const atlas = raster.Atlas{ .width = 4, .height = 4, .coverage = &coverage };
    var want = try golden(&list, atlas);
    defer want.deinit(std.testing.allocator);
    var got: [width * height]Color = undefined;
    try throughSdl(&list, atlas, &got);
    return worst(want.pixels, &got);
}

test "opaque fills and lines under nested clips match raster.draw exactly" {
    try std.testing.expectEqual(@as(u8, 0), try compare(.{ .tint = 255 }));
}

test "translucent fills and lines stay within 1 per channel of raster.draw" {
    try std.testing.expect(try compare(.{ .tint = 128 }) <= 1);
}

test "opaque glyphs and images match raster.draw exactly" {
    try std.testing.expectEqual(@as(u8, 0), try compare(.{ .tint = 255, .textured = true }));
}

test "partial coverage and translucent texels stay within 2 per channel" {
    const s = Scene{ .tint = 128, .textured = true, .texel = .{ .r = 9, .g = 99, .b = 199, .a = 128 }, .coverage = 128 };
    try std.testing.expect(try compare(s) <= 2);
}

test "image textures not drawn in a frame are dropped at the next frame" {
    const surface = c.SDL_CreateSurface(8, 8, c.SDL_PIXELFORMAT_RGBA32) orelse return error.SdlSurface;
    defer c.SDL_DestroySurface(surface);
    const renderer = c.SDL_CreateSoftwareRenderer(surface) orelse return error.SdlRenderer;
    defer c.SDL_DestroyRenderer(renderer);
    var textures = sdl.geometry.Textures.init(std.testing.allocator, renderer);
    defer textures.deinit();
    var list = draw_list.DrawList.init(std.testing.allocator, 8, 8);
    defer list.deinit();
    const texels = @as([6]Color, @splat(Color.rgb(1, 2, 3)));
    try list.image(rect(0, 0, 3, 2), .{ .width = 3, .height = 2, .pixels = &texels });
    var batch = render.geometry.Batch.init(std.testing.allocator);
    defer batch.deinit();
    try batch.build(&list, null);
    try textures.beginFrame();
    try sdl.geometry.draw(renderer, &textures, &batch);
    try std.testing.expectEqual(@as(u32, 1), textures.images.count());
    try textures.beginFrame();
    try std.testing.expectEqual(@as(u32, 1), textures.images.count());
    try textures.beginFrame();
    try std.testing.expectEqual(@as(u32, 0), textures.images.count());
}

test "the presenter clears to opaque black and draws the list like raster.draw" {
    var list = draw_list.DrawList.init(std.testing.allocator, width, height);
    defer list.deinit();
    const texels = @as([6]Color, @splat(Color.rgb(9, 99, 199)));
    try scene(&list, .{ .tint = 255, .textured = true }, &texels);
    const coverage = @as([16]u8, @splat(255));
    const atlas = raster.Atlas{ .width = 4, .height = 4, .coverage = &coverage };
    var want = try golden(&list, atlas);
    defer want.deinit(std.testing.allocator);
    const surface = c.SDL_CreateSurface(width, height, c.SDL_PIXELFORMAT_RGBA32) orelse return error.SdlSurface;
    defer c.SDL_DestroySurface(surface);
    const renderer = c.SDL_CreateSoftwareRenderer(surface) orelse return error.SdlRenderer;
    defer c.SDL_DestroyRenderer(renderer);
    var presenter = sdl.geometry.Presenter.init(std.testing.allocator, renderer);
    defer presenter.deinit();
    try presenter.frame(&list, atlas);
    try presenter.frame(&list, atlas);
    try std.testing.expectEqual(@as(u32, 1), presenter.textures.images.count());
    const read = c.SDL_RenderReadPixels(renderer, null) orelse return error.SdlRead;
    defer c.SDL_DestroySurface(read);
    const rgba = c.SDL_ConvertSurface(read, c.SDL_PIXELFORMAT_RGBA32) orelse return error.SdlConvert;
    defer c.SDL_DestroySurface(rgba);
    const bytes: [*]const u8 = @ptrCast(rgba.*.pixels.?);
    const pitch: usize = @intCast(rgba.*.pitch);
    var got: [width * height]Color = undefined;
    for (0..height) |y| {
        const row: [*]const Color = @ptrCast(@alignCast(bytes + y * pitch));
        @memcpy(got[y * width ..][0..width], row[0..width]);
    }
    try std.testing.expectEqual(@as(u8, 0), worst(want.pixels, &got));
}
