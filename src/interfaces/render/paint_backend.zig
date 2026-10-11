//! The desktop Paint backend (RA8EMU-1157): the shared ra8_widget Paint
//! table bound to the emulator's CPU rasterizer, so the GUI paints through
//! the same table the firmware's host backend serves (RA8FW-951). This is
//! the temporary wrap of raster.zig behind Paint, RA8EMU-1144's first step:
//! the table carries the paint semantics (fallbacks, clip stack, alpha),
//! raster.zig stays the desktop framebuffer until the follow-up PRs move
//! the storage to ra8_gfx.Surface and delete it.
const std = @import("std");
const widget = @import("ra8_widget");
const gfx = @import("ra8_gfx");
const raster = @import("raster.zig");
const draw_list = @import("draw_list.zig");

const Color = draw_list.Color;
const Rect = draw_list.Rect;

/// The blit pixel formats, as ra8_gfx defines them.
pub const Format = gfx.Format;

/// The widget colour word (0x00RRGGBB) as a draw colour.
fn colorOf(word: u32) Color {
    return Color.rgb(@truncate(word >> 16), @truncate(word >> 8), @truncate(word));
}

fn faceOf(value: u8) gfx.Face {
    return if (value == 1) .serif else .sans;
}

fn weightOf(value: u8) gfx.Weight {
    return if (value == 1) .bold else .regular;
}

/// A Paint backend over `fb`: the clip stack and every primitive the shared
/// table serves. Text goes through ra8_gfx's faces at pixel level, the way
/// the firmware's host backend draws it.
pub const Backend = struct {
    allocator: std.mem.Allocator,
    fb: *raster.Framebuffer,
    clips: std.ArrayListUnmanaged(Rect) = .empty,

    pub fn init(allocator: std.mem.Allocator, fb: *raster.Framebuffer) Backend {
        return .{ .allocator = allocator, .fb = fb };
    }

    pub fn deinit(self: *Backend) void {
        self.clips.deinit(self.allocator);
    }

    /// The clip later draws land in: the whole surface when none is pushed.
    pub fn clip(self: *const Backend) Rect {
        const items = self.clips.items;
        return if (items.len == 0) self.fb.bounds() else items[items.len - 1];
    }

    /// Narrow the clip to `area` until the matching popClip.
    pub fn pushClip(self: *Backend, area: Rect) !void {
        try self.clips.append(self.allocator, self.clip().intersect(area));
    }

    pub fn popClip(self: *Backend) void {
        _ = self.clips.pop();
    }

    /// The shared Paint table, every member bound.
    pub fn paint(self: *Backend) widget.types.Paint {
        return .{
            .user = self,
            .fill_rect = fillRect,
            .draw_text = drawText,
            .text_size = textSize,
            .draw_text_face = drawTextFace,
            .text_size_face = textSizeFace,
            .draw_text_style = drawTextStyle,
            .text_size_style = textSizeStyle,
            .draw_line = drawLine,
            .blit = blit,
            .push_clip = pushClipCb,
            .pop_clip = popClipCb,
            .fill_rect_alpha = fillRectAlpha,
        };
    }
};

fn backendOf(user: ?*anyopaque) *Backend {
    return @ptrCast(@alignCast(user.?));
}

fn areaOf(x: i32, y: i32, w: i32, h: i32, clip: Rect) Rect {
    return (Rect{ .x = x, .y = y, .w = w, .h = h }).intersect(clip);
}

fn fillRect(user: ?*anyopaque, x: i32, y: i32, w: i32, h: i32, color: u32) callconv(.c) void {
    const self = backendOf(user);
    const area = areaOf(x, y, w, h, self.clip());
    if (area.empty()) return;
    raster.fillRect(self.fb, area, colorOf(color));
}

fn fillRectAlpha(user: ?*anyopaque, x: i32, y: i32, w: i32, h: i32, color: u32, alpha: u8) callconv(.c) void {
    if (alpha == 0) return;
    const self = backendOf(user);
    const area = areaOf(x, y, w, h, self.clip());
    if (area.empty()) return;
    var painted = colorOf(color);
    painted.a = alpha;
    raster.fillRect(self.fb, area, painted);
}

fn drawLine(user: ?*anyopaque, x0: i32, y0: i32, x1: i32, y1: i32, color: u32) callconv(.c) void {
    const self = backendOf(user);
    raster.line(self.fb, .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .color = colorOf(color) }, self.clip());
}

fn blit(user: ?*anyopaque, x: i32, y: i32, w: i32, h: i32, pixels: [*]const u8, stride: i32, format: u8) callconv(.c) void {
    const self = backendOf(user);
    if (w <= 0 or h <= 0 or stride <= 0) return;
    const kind = std.enums.fromInt(gfx.Format, format) orelse return;
    const area = areaOf(x, y, w, h, self.clip());
    if (area.empty()) return;
    const pitch: usize = @intCast(stride);
    var py = area.y;
    while (py < area.y + area.h) : (py += 1) {
        const row = pixels[@as(usize, @intCast(py - y)) * pitch ..];
        var px = area.x;
        while (px < area.x + area.w) : (px += 1) {
            const at = @as(usize, @intCast(px - x)) * kind.bytes();
            self.fb.put(px, py, pixelOf(kind, row[at..]));
        }
    }
}

/// The pixel at `bytes[0..]` in `kind`, read out as an RGBA colour. The
/// read rules are ra8_gfx's (little-endian multi-byte, grey and the small
/// RGB formats opaque), kept here until raster.zig is deleted.
fn pixelOf(kind: gfx.Format, bytes: [*]const u8) Color {
    switch (kind) {
        .gray8 => {
            const v = bytes[0];
            return Color.rgb(v, v, v);
        },
        .rgb565 => {
            const v: u32 = @as(u32, bytes[0]) | @as(u32, bytes[1]) << 8;
            const r: u8 = scale5(@intCast((v >> 11) & 0x1F));
            const g: u8 = scale6(@intCast((v >> 5) & 0x3F));
            const b: u8 = scale5(@intCast(v & 0x1F));
            return Color.rgb(r, g, b);
        },
        .rgb888 => return Color.rgb(bytes[2], bytes[1], bytes[0]),
        .argb8888 => {
            const v: u32 = @as(u32, bytes[0]) | @as(u32, bytes[1]) << 8 | @as(u32, bytes[2]) << 16 | @as(u32, bytes[3]) << 24;
            return .{ .r = @truncate(v >> 16), .g = @truncate(v >> 8), .b = @truncate(v), .a = @truncate(v >> 24) };
        },
    }
}

fn scale5(v: u8) u8 {
    return @intCast((@as(u32, v) * 255 + 15) / 31);
}

fn scale6(v: u8) u8 {
    return @intCast((@as(u32, v) * 255 + 3) / 7);
}

/// Text draws hand each pixel over solid; the font has already mixed the
/// glyph's coverage between foreground and background.
fn putPixel(user: ?*anyopaque, x: i32, y: i32, color: u32) callconv(.c) void {
    const self = backendOf(user);
    if (!self.clip().contains(x, y)) return;
    self.fb.put(x, y, colorOf(color));
}

fn drawText(user: ?*anyopaque, x: i32, y: i32, str: [*:0]const u8, fg: u32, bg: u32) callconv(.c) void {
    gfx.text.drawSans(str, x, y, fg, bg, user, putPixel);
}

fn drawTextFace(user: ?*anyopaque, x: i32, y: i32, str: [*:0]const u8, family: u8, fg: u32, bg: u32) callconv(.c) void {
    if (faceOf(family) == .serif) gfx.text.drawSerif(str, x, y, fg, bg, user, putPixel) else gfx.text.drawSans(str, x, y, fg, bg, user, putPixel);
}

fn drawTextStyle(user: ?*anyopaque, x: i32, y: i32, str: [*:0]const u8, family: u8, stroke: u8, size: u8, fg: u32, bg: u32) callconv(.c) void {
    gfx.text.drawStyle(str, x, y, faceOf(family), weightOf(stroke), size, fg, bg, user, putPixel);
}

fn store(extent: gfx.Extent, out_w: *i32, out_h: *i32) void {
    out_w.* = @intCast(extent.width);
    out_h.* = @intCast(extent.height);
}

fn textSize(_: ?*anyopaque, str: [*:0]const u8, out_w: *i32, out_h: *i32) callconv(.c) void {
    store(gfx.text.measure(str, .sans), out_w, out_h);
}

fn textSizeFace(_: ?*anyopaque, str: [*:0]const u8, family: u8, out_w: *i32, out_h: *i32) callconv(.c) void {
    store(gfx.text.measure(str, faceOf(family)), out_w, out_h);
}

fn textSizeStyle(_: ?*anyopaque, str: [*:0]const u8, family: u8, stroke: u8, size: u8, out_w: *i32, out_h: *i32) callconv(.c) void {
    store(gfx.text.measureStyle(str, faceOf(family), weightOf(stroke), size), out_w, out_h);
}

fn pushClipCb(user: ?*anyopaque, x: i32, y: i32, w: i32, h: i32) callconv(.c) void {
    backendOf(user).pushClip(.{ .x = x, .y = y, .w = w, .h = h }) catch {};
}

fn popClipCb(user: ?*anyopaque) callconv(.c) void {
    backendOf(user).popClip();
}
