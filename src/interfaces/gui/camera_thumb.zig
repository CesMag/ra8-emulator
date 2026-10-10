//! A small preview of the picture or clip the camera panel's media row chose
//! (RA8EMU-500). It is read and decoded from the file itself, never pulled
//! from the running source, so drawing it cannot advance a video or eat a
//! pipe's frame. The decoded picture is box-averaged down to fit a square
//! of `side` pixels, keeping its shape, and drawn as one image quad.
const std = @import("std");
const draw_list = @import("../render/draw_list.zig");
const decoded = @import("ra8_host").camera.decoded;
const image_source = @import("ra8_host").camera.image_file;
const y4m = @import("ra8_host").camera.y4m;
const yuv = @import("ra8_host").camera.y4m_frame;
const Color = draw_list.Color;

/// The preview's longest edge, matching a panel button.
pub const side: u32 = 24;

pub const Thumb = struct {
    width: u32,
    height: u32,
    pixels: []Color,

    pub fn image(self: Thumb) draw_list.Image {
        return .{ .width = self.width, .height = self.height, .pixels = self.pixels };
    }

    pub fn deinit(self: Thumb, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

/// The preview's size for a `width` by `height` picture: the longer edge
/// becomes at most `limit`, the other keeps the ratio, neither drops to 0,
/// and a picture smaller than `limit` is never enlarged.
pub fn fit(width: u32, height: u32, limit: u32) struct { u32, u32 } {
    const long = @max(width, height);
    if (long <= limit) return .{ width, height };
    const w: u32 = @intCast(@max(1, @as(u64, width) * limit / long));
    const h: u32 = @intCast(@max(1, @as(u64, height) * limit / long));
    return .{ w, h };
}

/// Averages every source pixel that falls in each preview cell.
pub fn shrink(allocator: std.mem.Allocator, picture: decoded.Image, limit: u32) !Thumb {
    const w, const h = fit(picture.width, picture.height, limit);
    const pixels = try allocator.alloc(Color, @as(usize, w) * h);
    for (0..h) |y| {
        const y0 = span(y, picture.height, h);
        const y1 = span(y + 1, picture.height, h);
        for (0..w) |x| {
            const x0 = span(x, picture.width, w);
            const x1 = span(x + 1, picture.width, w);
            pixels[y * w + x] = average(picture, x0, @max(x1, x0 + 1), y0, @max(y1, y0 + 1));
        }
    }
    return .{ .width = w, .height = h, .pixels = pixels };
}

fn span(cell: usize, total: u32, cells: u32) usize {
    return @intCast(@as(u64, cell) * total / cells);
}

fn average(picture: decoded.Image, x0: usize, x1: usize, y0: usize, y1: usize) Color {
    var sum = [3]u64{ 0, 0, 0 };
    for (y0..y1) |y| {
        for (x0..x1) |x| {
            const p = picture.get(y * picture.width + x);
            sum[0] += p[0];
            sum[1] += p[1];
            sum[2] += p[2];
        }
    }
    const count = (x1 - x0) * (y1 - y0);
    return Color.rgb(@intCast(sum[0] / count), @intCast(sum[1] / count), @intCast(sum[2] / count));
}

/// The longest Y4M header or FRAME line read before the clip is refused.
const max_line: usize = 256;

/// Reads `name` from `dir` and shrinks it to `side`: a picture whole, a
/// Y4M clip by its first frame.
pub fn load(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) !Thumb {
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);
    var head: [max_line]u8 = undefined;
    const got = try file.readPositionalAll(io, &head, 0);
    if (std.mem.startsWith(u8, head[0..got], y4m.magic)) return clip(allocator, io, file, head[0..got]);
    const size = try file.length(io);
    if (size > image_source.max_file_bytes) return error.FileTooBig;
    const bytes = try allocator.alloc(u8, @intCast(size));
    defer allocator.free(bytes);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.Truncated;
    const picture = try image_source.decodeAny(allocator, bytes);
    defer picture.deinit(allocator);
    return shrink(allocator, picture, side);
}

/// The clip's first frame: header line, FRAME line, then its planes.
fn clip(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, head: []const u8) !Thumb {
    const header_end = std.mem.indexOfScalar(u8, head, '\n') orelse return error.BadHeader;
    const header = try y4m.parse(head[0..header_end]);
    var line: [max_line]u8 = undefined;
    const got = try file.readPositionalAll(io, &line, header_end + 1);
    const frame_end = std.mem.indexOfScalar(u8, line[0..got], '\n') orelse return error.Truncated;
    if (!std.mem.startsWith(u8, line[0..frame_end], "FRAME")) return error.BadHeader;
    const planes = try allocator.alloc(u8, @intCast(header.frameBytes()));
    defer allocator.free(planes);
    const read = try file.readPositionalAll(io, planes, header_end + 1 + frame_end + 1);
    if (read != planes.len) return error.Truncated;
    const picture = try decoded.Image.alloc(allocator, header.width, header.height);
    defer picture.deinit(allocator);
    yuv.toRgb(header, planes, picture.pixels);
    return shrink(allocator, picture, side);
}

/// Appends the preview centred in `area`; no preview, nothing drawn.
pub fn draw(list: *draw_list.DrawList, area: draw_list.Rect, thumb: ?Thumb) !void {
    const t = thumb orelse return;
    const w: i32 = @intCast(t.width);
    const h: i32 = @intCast(t.height);
    const at = draw_list.Rect{ .x = area.x + @divTrunc(area.w - w, 2), .y = area.y + @divTrunc(area.h - h, 2), .w = w, .h = h };
    try list.image(at, t.image());
}
