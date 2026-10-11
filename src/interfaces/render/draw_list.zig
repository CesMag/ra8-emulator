//! What widgets draw (RA8EMU-617, ADR 0001 in the knowledge base, RA8EMU-A-8). A widget
//! appends shapes to a DrawList; a backend draws the list. The CPU
//! rasterizer (raster.zig) draws it on the board and in golden-image tests,
//! and the host backend presents the same pixels, so a pane looks the same
//! everywhere. Every shape carries the clip in force when it was added.
const std = @import("std");

/// One RGBA8 pixel, straight (not premultiplied) alpha, in the byte order
/// SDL calls RGBA32.
pub const Color = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }
};

/// A pixel rectangle; `w` or `h` at or below zero is empty.
pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn intersect(self: Rect, other: Rect) Rect {
        const x0 = @max(self.x, other.x);
        const y0 = @max(self.y, other.y);
        const x1 = @min(self.x + self.w, other.x + other.w);
        const y1 = @min(self.y + self.h, other.y + other.h);
        return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
    }

    pub fn empty(self: Rect) bool {
        return self.w <= 0 or self.h <= 0;
    }

    pub fn contains(self: Rect, x: i32, y: i32) bool {
        return x >= self.x and y >= self.y and x < self.x + self.w and y < self.y + self.h;
    }
};

/// Rows of RGBA pixels an image quad scales into its area.
pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []const Color,
};

pub const Fill = struct { area: Rect, color: Color };
pub const Line = struct { x0: i32, y0: i32, x1: i32, y1: i32, color: Color };
/// A glyph from the font atlas: the atlas cell at (`cell_x`, `cell_y`)
/// covers `area` one to one, and its coverage scales `color`'s alpha.
pub const Glyph = struct { area: Rect, cell_x: u32, cell_y: u32, color: Color };
/// `smooth` samples filtered instead of nearest (RA8EMU-965): for an image
/// shown at a fractional scale, where nearest would make text shimmer.
pub const Quad = struct { area: Rect, image: Image, smooth: bool = false };

pub const Shape = union(enum) {
    fill: Fill,
    line: Line,
    glyph: Glyph,
    image: Quad,
};

pub const Command = struct { shape: Shape, clip: Rect };

pub const DrawList = struct {
    allocator: std.mem.Allocator,
    /// The whole surface; the clip when none is pushed.
    bounds: Rect,
    commands: std.ArrayListUnmanaged(Command) = .empty,
    clips: std.ArrayListUnmanaged(Rect) = .empty,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) DrawList {
        return .{ .allocator = allocator, .bounds = .{ .x = 0, .y = 0, .w = @intCast(width), .h = @intCast(height) } };
    }

    pub fn deinit(self: *DrawList) void {
        self.commands.deinit(self.allocator);
        self.clips.deinit(self.allocator);
    }

    /// Start the next frame, keeping the storage.
    pub fn clear(self: *DrawList) void {
        self.commands.clearRetainingCapacity();
        self.clips.clearRetainingCapacity();
    }

    pub fn clip(self: *const DrawList) Rect {
        const items = self.clips.items;
        return if (items.len == 0) self.bounds else items[items.len - 1];
    }

    /// Narrow the clip to `area` until the matching popClip.
    pub fn pushClip(self: *DrawList, area: Rect) !void {
        try self.clips.append(self.allocator, self.clip().intersect(area));
    }

    pub fn popClip(self: *DrawList) void {
        _ = self.clips.pop();
    }

    pub fn fill(self: *DrawList, area: Rect, color: Color) !void {
        if (area.intersect(self.clip()).empty()) return;
        try self.add(.{ .fill = .{ .area = area, .color = color } });
    }

    pub fn line(self: *DrawList, x0: i32, y0: i32, x1: i32, y1: i32, color: Color) !void {
        try self.add(.{ .line = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .color = color } });
    }

    pub fn glyph(self: *DrawList, area: Rect, cell_x: u32, cell_y: u32, color: Color) !void {
        if (area.intersect(self.clip()).empty()) return;
        try self.add(.{ .glyph = .{ .area = area, .cell_x = cell_x, .cell_y = cell_y, .color = color } });
    }

    pub fn image(self: *DrawList, area: Rect, source: Image) !void {
        return self.scaledImage(area, source, false);
    }

    /// `source` stretched over `area`, filtered when `smooth`.
    pub fn scaledImage(self: *DrawList, area: Rect, source: Image, smooth: bool) !void {
        if (area.intersect(self.clip()).empty()) return;
        try self.add(.{ .image = .{ .area = area, .image = source, .smooth = smooth } });
    }

    fn add(self: *DrawList, shape: Shape) !void {
        const now = self.clip();
        if (now.empty()) return;
        try self.commands.append(self.allocator, .{ .shape = shape, .clip = now });
    }
};
