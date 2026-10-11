//! Batches a draw list into textured triangles for SDL's renderer geometry
//! path (RA8EMU-734, ADR 0001 in the knowledge base, RA8EMU-A-8 step 4). Pure Zig: the SDL
//! presenter sets each run's clip rect and texture, then draws its indices.
//! Lines become 1 px quads per Bresenham row span, so the GPU covers the same
//! pixels raster.zig does on every driver.
const std = @import("std");
const draw_list = @import("draw_list.zig");
const raster = @import("raster.zig");
const Color = draw_list.Color;
const Rect = draw_list.Rect;

/// Same layout as SDL_Vertex: position, float colour, texture coordinate.
pub const Vertex = extern struct {
    x: f32,
    y: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    u: f32,
    v: f32,
};

/// What a run samples: nothing, the glyph atlas, or one image.
pub const Texture = union(enum) {
    none,
    atlas,
    image: draw_list.Image,
    /// The same pixels sampled filtered (RA8EMU-965).
    smooth: draw_list.Image,

    pub fn eql(self: Texture, other: Texture) bool {
        return switch (self) {
            .none => other == .none,
            .atlas => other == .atlas,
            .image => |mine| other == .image and same(mine, other.image),
            .smooth => |mine| other == .smooth and same(mine, other.smooth),
        };
    }
};

fn same(a: draw_list.Image, b: draw_list.Image) bool {
    return a.pixels.ptr == b.pixels.ptr and a.width == b.width and a.height == b.height;
}

/// Indices `first .. first + count` share one texture and one clip rect.
pub const Run = struct {
    texture: Texture,
    clip: Rect,
    first: u32,
    count: u32,
};

const Uv = struct { u0: f32 = 0, v0: f32 = 0, u1: f32 = 0, v1: f32 = 0 };
const Span = struct { y: i32, lo: i32, hi: i32 };

pub const Batch = struct {
    allocator: std.mem.Allocator,
    vertices: std.ArrayListUnmanaged(Vertex) = .empty,
    indices: std.ArrayListUnmanaged(u32) = .empty,
    runs: std.ArrayListUnmanaged(Run) = .empty,

    pub fn init(allocator: std.mem.Allocator) Batch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Batch) void {
        self.vertices.deinit(self.allocator);
        self.indices.deinit(self.allocator);
        self.runs.deinit(self.allocator);
    }

    /// Start the next frame, keeping the storage.
    pub fn clear(self: *Batch) void {
        self.vertices.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();
        self.runs.clearRetainingCapacity();
    }

    /// Rebuild from `list`. Glyphs need `atlas` for their texture
    /// coordinates; without one they are dropped, as raster.draw drops them.
    pub fn build(self: *Batch, list: *const draw_list.DrawList, atlas: ?raster.Atlas) !void {
        self.clear();
        for (list.commands.items) |command| {
            const clip = command.clip.intersect(list.bounds);
            if (clip.empty()) continue;
            switch (command.shape) {
                .fill => |shape| try self.fill(clip, shape),
                .line => |shape| try self.line(clip, shape),
                .glyph => |shape| if (atlas) |cells| try self.glyph(clip, cells, shape),
                .image => |shape| try self.image(clip, shape),
            }
        }
    }

    fn fill(self: *Batch, clip: Rect, shape: draw_list.Fill) !void {
        const area = shape.area.intersect(clip);
        if (area.empty()) return;
        try self.quad(.none, clip, area, shape.color, .{});
    }

    /// Bresenham as raster.zig walks it, both end points included; each run
    /// of visible pixels on one row becomes one quad.
    fn line(self: *Batch, clip: Rect, shape: draw_list.Line) !void {
        const dx: i32 = @intCast(@abs(shape.x1 - shape.x0));
        const dy: i32 = -@as(i32, @intCast(@abs(shape.y1 - shape.y0)));
        const step_x: i32 = if (shape.x0 < shape.x1) 1 else -1;
        const step_y: i32 = if (shape.y0 < shape.y1) 1 else -1;
        var x = shape.x0;
        var y = shape.y0;
        var err = dx + dy;
        var span: ?Span = null;
        while (true) {
            if (clip.contains(x, y)) {
                const extends = if (span) |open| open.y == y else false;
                if (extends) {
                    span.?.lo = @min(span.?.lo, x);
                    span.?.hi = @max(span.?.hi, x);
                } else {
                    if (span) |open| try self.spanQuad(clip, open, shape.color);
                    span = .{ .y = y, .lo = x, .hi = x };
                }
            } else if (span) |open| {
                try self.spanQuad(clip, open, shape.color);
                span = null;
            }
            if (x == shape.x1 and y == shape.y1) break;
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
        if (span) |open| try self.spanQuad(clip, open, shape.color);
    }

    fn spanQuad(self: *Batch, clip: Rect, span: Span, color: Color) !void {
        const area = Rect{ .x = span.lo, .y = span.y, .w = span.hi - span.lo + 1, .h = 1 };
        try self.quad(.none, clip, area, color, .{});
    }

    /// Edges map to texel edges, so with nearest sampling every pixel centre
    /// lands on the centre of the atlas texel raster.zig reads.
    fn glyph(self: *Batch, clip: Rect, atlas: raster.Atlas, shape: draw_list.Glyph) !void {
        const area = shape.area.intersect(clip);
        if (area.empty()) return;
        const width: f32 = @floatFromInt(atlas.width);
        const height: f32 = @floatFromInt(atlas.height);
        const left: f32 = @floatFromInt(@as(i64, shape.cell_x) + (area.x - shape.area.x));
        const top: f32 = @floatFromInt(@as(i64, shape.cell_y) + (area.y - shape.area.y));
        const uv = Uv{
            .u0 = left / width,
            .v0 = top / height,
            .u1 = (left + float(area.w)) / width,
            .v1 = (top + float(area.h)) / height,
        };
        try self.quad(.atlas, clip, area, shape.color, uv);
    }

    /// The whole image scales into its area; a clipped area keeps the
    /// matching part of the image.
    fn image(self: *Batch, clip: Rect, shape: draw_list.Quad) !void {
        const area = shape.area.intersect(clip);
        if (area.empty() or shape.image.width == 0 or shape.image.height == 0) return;
        const span_w = float(shape.area.w);
        const span_h = float(shape.area.h);
        const uv = Uv{
            .u0 = float(area.x - shape.area.x) / span_w,
            .v0 = float(area.y - shape.area.y) / span_h,
            .u1 = float(area.x + area.w - shape.area.x) / span_w,
            .v1 = float(area.y + area.h - shape.area.y) / span_h,
        };
        const texture: Texture = if (shape.smooth) .{ .smooth = shape.image } else .{ .image = shape.image };
        try self.quad(texture, clip, area, Color.rgb(255, 255, 255), uv);
    }

    /// Two triangles over `area`, in the run for `texture` and `clip`.
    fn quad(self: *Batch, texture: Texture, clip: Rect, area: Rect, color: Color, uv: Uv) !void {
        try self.useRun(texture, clip);
        const base: u32 = @intCast(self.vertices.items.len);
        const x0 = float(area.x);
        const y0 = float(area.y);
        const x1 = float(area.x + area.w);
        const y1 = float(area.y + area.h);
        try self.vertices.appendSlice(self.allocator, &.{
            vertex(x0, y0, color, uv.u0, uv.v0),
            vertex(x1, y0, color, uv.u1, uv.v0),
            vertex(x0, y1, color, uv.u0, uv.v1),
            vertex(x1, y1, color, uv.u1, uv.v1),
        });
        try self.indices.appendSlice(self.allocator, &.{ base, base + 1, base + 2, base + 2, base + 1, base + 3 });
        self.runs.items[self.runs.items.len - 1].count += 6;
    }

    fn useRun(self: *Batch, texture: Texture, clip: Rect) !void {
        const runs = self.runs.items;
        if (runs.len > 0) {
            const last = runs[runs.len - 1];
            if (last.texture.eql(texture) and std.meta.eql(last.clip, clip)) return;
        }
        const first: u32 = @intCast(self.indices.items.len);
        try self.runs.append(self.allocator, .{ .texture = texture, .clip = clip, .first = first, .count = 0 });
    }
};

fn float(value: i32) f32 {
    return @floatFromInt(value);
}

fn vertex(x: f32, y: f32, color: Color, u: f32, v: f32) Vertex {
    return .{
        .x = x,
        .y = y,
        .r = channel(color.r),
        .g = channel(color.g),
        .b = channel(color.b),
        .a = channel(color.a),
        .u = u,
        .v = v,
    };
}

fn channel(value: u8) f32 {
    return @as(f32, @floatFromInt(value)) / 255.0;
}
