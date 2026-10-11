//! Draws a DrawList into an RGBA framebuffer on the CPU (RA8EMU-617,
//! ADR 0001 in the knowledge base, RA8EMU-A-8). The board draws its panes this way, golden
//! image tests compare these pixels, and the host backend presents them.
//! Shapes blend source-over with straight alpha, rounded to nearest.
const std = @import("std");
const draw_list = @import("draw_list.zig");
const Color = draw_list.Color;
const Rect = draw_list.Rect;

/// A font atlas: one byte of coverage per pixel, in rows of `width`.
pub const Atlas = struct {
    width: u32,
    height: u32,
    coverage: []const u8,
};

pub const Framebuffer = struct {
    width: u32,
    height: u32,
    pixels: []Color,

    /// A framebuffer of transparent black.
    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Framebuffer {
        const pixels = try allocator.alloc(Color, @as(usize, width) * height);
        @memset(pixels, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
        return .{ .width = width, .height = height, .pixels = pixels };
    }

    pub fn deinit(self: *Framebuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }

    pub fn at(self: *const Framebuffer, x: u32, y: u32) Color {
        return self.pixels[@as(usize, y) * self.width + x];
    }

    pub fn bounds(self: *const Framebuffer) Rect {
        return .{ .x = 0, .y = 0, .w = @intCast(self.width), .h = @intCast(self.height) };
    }

    pub fn put(self: *Framebuffer, x: i32, y: i32, color: Color) void {
        const index = @as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x));
        self.pixels[index] = blend(self.pixels[index], color);
    }
};

/// `src` over `dst`.
pub fn blend(dst: Color, src: Color) Color {
    if (src.a == 255) return src;
    if (src.a == 0) return dst;
    const a: u32 = src.a;
    const rest = 255 - a;
    return .{
        .r = mix(src.r, dst.r, a, rest),
        .g = mix(src.g, dst.g, a, rest),
        .b = mix(src.b, dst.b, a, rest),
        .a = @intCast(a + (@as(u32, dst.a) * rest + 127) / 255),
    };
}

fn mix(src: u8, dst: u8, a: u32, rest: u32) u8 {
    return @intCast((@as(u32, src) * a + @as(u32, dst) * rest + 127) / 255);
}

/// Draw every command in `list` into `target`, in order. Glyphs need
/// `atlas`; without one they draw nothing.
pub fn draw(target: *Framebuffer, list: *const draw_list.DrawList, atlas: ?Atlas) void {
    for (list.commands.items) |command| {
        const clip = command.clip.intersect(target.bounds());
        if (clip.empty()) continue;
        switch (command.shape) {
            .fill => |shape| fillRect(target, shape.area.intersect(clip), shape.color),
            .line => |shape| line(target, shape, clip),
            .glyph => |shape| if (atlas) |cells| glyph(target, cells, shape, clip),
            .image => |shape| image(target, shape, clip),
        }
    }
}

pub fn fillRect(target: *Framebuffer, area: Rect, color: Color) void {
    var y = area.y;
    while (y < area.y + area.h) : (y += 1) {
        var x = area.x;
        while (x < area.x + area.w) : (x += 1) target.put(x, y, color);
    }
}

/// Bresenham, both end points included.
pub fn line(target: *Framebuffer, shape: draw_list.Line, clip: Rect) void {
    const dx: i32 = @intCast(@abs(shape.x1 - shape.x0));
    const dy: i32 = -@as(i32, @intCast(@abs(shape.y1 - shape.y0)));
    const step_x: i32 = if (shape.x0 < shape.x1) 1 else -1;
    const step_y: i32 = if (shape.y0 < shape.y1) 1 else -1;
    var x = shape.x0;
    var y = shape.y0;
    var err = dx + dy;
    while (true) {
        if (clip.contains(x, y)) target.put(x, y, shape.color);
        if (x == shape.x1 and y == shape.y1) return;
        const doubled = 2 * err;
        if (doubled >= dy) {
            err += dy;
            x += step_x;
        }
        if (doubled <= dx) {
            err += dx;
            y += step_y;
        }
    }
}

fn glyph(target: *Framebuffer, atlas: Atlas, shape: draw_list.Glyph, clip: Rect) void {
    const area = shape.area.intersect(clip);
    var y = area.y;
    while (y < area.y + area.h) : (y += 1) {
        var x = area.x;
        while (x < area.x + area.w) : (x += 1) {
            const cell_x = shape.cell_x + @as(u32, @intCast(x - shape.area.x));
            const cell_y = shape.cell_y + @as(u32, @intCast(y - shape.area.y));
            if (cell_x >= atlas.width or cell_y >= atlas.height) continue;
            const coverage: u32 = atlas.coverage[@as(usize, cell_y) * atlas.width + cell_x];
            var color = shape.color;
            color.a = @intCast((@as(u32, color.a) * coverage + 127) / 255);
            target.put(x, y, color);
        }
    }
}

/// Nearest-neighbour scale of the image into its area.
fn image(target: *Framebuffer, shape: draw_list.Quad, clip: Rect) void {
    const source = shape.image;
    const area = shape.area.intersect(clip);
    if (area.empty() or source.width == 0 or source.height == 0) return;
    if (shape.smooth) return smoothImage(target, shape, area);
    const span_w: u64 = @intCast(shape.area.w);
    const span_h: u64 = @intCast(shape.area.h);
    var y = area.y;
    while (y < area.y + area.h) : (y += 1) {
        const from_y: usize = @intCast(@as(u64, @intCast(y - shape.area.y)) * source.height / span_h);
        var x = area.x;
        while (x < area.x + area.w) : (x += 1) {
            const from_x: usize = @intCast(@as(u64, @intCast(x - shape.area.x)) * source.width / span_w);
            target.put(x, y, source.pixels[from_y * source.width + from_x]);
        }
    }
}

/// Bilinear sampling in 8-bit fixed point (RA8EMU-965), so the CPU path
/// gives the same pixels on every host.
fn smoothImage(target: *Framebuffer, shape: draw_list.Quad, area: Rect) void {
    const source = shape.image;
    var y = area.y;
    while (y < area.y + area.h) : (y += 1) {
        const row = Tap.of(y - shape.area.y, shape.area.h, source.height);
        var x = area.x;
        while (x < area.x + area.w) : (x += 1) {
            const col = Tap.of(x - shape.area.x, shape.area.w, source.width);
            const top = between(source.pixels[row.near * source.width + col.near], source.pixels[row.near * source.width + col.far], col.frac);
            const bottom = between(source.pixels[row.far * source.width + col.near], source.pixels[row.far * source.width + col.far], col.frac);
            target.put(x, y, between(top, bottom, row.frac));
        }
    }
}

/// The two source pixels a target pixel's centre falls between, and how
/// far towards the second it sits, in 256ths.
const Tap = struct {
    near: usize,
    far: usize,
    frac: u32,

    fn of(offset: i32, span: i32, pixels: u32) Tap {
        const scaled = @divTrunc((2 * @as(i64, offset) + 1) * pixels * 256, 2 * @as(i64, span)) - 128;
        const last: i64 = (@as(i64, pixels) - 1) * 256;
        const at: u64 = @intCast(@min(@max(scaled, 0), last));
        const near: usize = @intCast(at >> 8);
        return .{ .near = near, .far = @min(near + 1, pixels - 1), .frac = @intCast(at & 0xFF) };
    }
};

fn between(a: Color, b: Color, frac: u32) Color {
    return .{ .r = lerp(a.r, b.r, frac), .g = lerp(a.g, b.g, frac), .b = lerp(a.b, b.b, frac), .a = lerp(a.a, b.a, frac) };
}

fn lerp(a: u8, b: u8, frac: u32) u8 {
    return @intCast((@as(u32, a) * (256 - frac) + @as(u32, b) * frac) >> 8);
}
