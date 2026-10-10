//! A still of the host window (RA8EMU-500): the last frame the window was
//! asked to present, written as a lossless PNG. With the headless platform
//! this is how the camera panel's layout is checked on a machine with no
//! display: numbered stills, one per state, that can be diffed or viewed.
const std = @import("std");
const png = @import("ra8_render").png;
const raster = @import("ra8_render").raster;
const Color = @import("ra8_render").draw_list.Color;

/// Copies `pixels` into `rgba` as opaque 8-bit RGBA; a window frame left
/// transparent anywhere is shown as it would be on screen, solid.
pub fn opaqueRgba(pixels: []const Color, rgba: []u8) png.Error!void {
    if (rgba.len != pixels.len * png.bytes_per_pixel) return png.Error.BadShape;
    for (pixels, 0..) |pixel, index| {
        const at = index * png.bytes_per_pixel;
        rgba[at..][0..png.bytes_per_pixel].* = .{ pixel.r, pixel.g, pixel.b, 0xFF };
    }
}

/// Writes `frame` to `writer` as a PNG of the frame's own size.
pub fn encode(allocator: std.mem.Allocator, writer: anytype, frame: raster.Framebuffer) !void {
    const rgba = try allocator.alloc(u8, frame.pixels.len * png.bytes_per_pixel);
    defer allocator.free(rgba);
    try opaqueRgba(frame.pixels, rgba);
    try png.encode(allocator, writer, frame.width, frame.height, rgba);
}

/// Saves `frame` as `file_name` in `dir`.
pub fn save(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, file_name: []const u8, frame: raster.Framebuffer) !void {
    var file = try dir.createFile(io, file_name, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try encode(allocator, &writer.interface, frame);
    try writer.interface.flush();
}

/// The name of still `index` for `stem`: `stem-0003.png`, so a run of
/// stills sorts in the order it was taken.
pub fn name(buffer: []u8, stem: []const u8, index: u32) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}-{d:0>4}.png", .{ stem, index });
}
