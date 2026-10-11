//! The raw frames a camera pipe carries (RA8EMU-584).
//!
//! `pipe:<path|->,<w>x<h>,<format>` names where the frames come from, their
//! size and their byte layout. The size and format are fixed for the run:
//! a pipe has no header, so each frame is exactly `frameBytes` bytes and the
//! next one starts right after it. Formats match ffmpeg's `-pix_fmt` names:
//! rgb24 (R, G, B), yuyv422 written as `yuyv` (Y0 U Y1 V, BT.601 studio
//! range) and rgb565 (little-endian, ffmpeg's rgb565le).
const std = @import("std");
const decoded = @import("../decoded_image.zig");
const yuv = @import("../y4m/frame.zig");

pub const Format = enum {
    rgb24,
    yuyv,
    rgb565,

    pub fn bytesPerPixel(self: Format) u32 {
        return if (self == .rgb24) 3 else 2;
    }
};

pub const Arg = struct {
    /// A named pipe, or "-" for standard input.
    path: []const u8,
    width: u32,
    height: u32,
    format: Format,

    pub fn frameBytes(self: Arg) usize {
        return @as(usize, self.width) * self.height * self.format.bytesPerPixel();
    }
};

/// `PATH,WxH,FORMAT`, split from the right so a path may hold commas.
pub fn parseArg(text: []const u8) error{BadValue}!Arg {
    const last = std.mem.lastIndexOfScalar(u8, text, ',') orelse return error.BadValue;
    const head = text[0..last];
    const middle = std.mem.lastIndexOfScalar(u8, head, ',') orelse return error.BadValue;
    const format = std.meta.stringToEnum(Format, text[last + 1 ..]) orelse return error.BadValue;
    const size = head[middle + 1 ..];
    const cross = std.mem.indexOfScalar(u8, size, 'x') orelse return error.BadValue;
    const width = std.fmt.parseInt(u32, size[0..cross], 10) catch return error.BadValue;
    const height = std.fmt.parseInt(u32, size[cross + 1 ..], 10) catch return error.BadValue;
    if (middle == 0 or width == 0 or height == 0) return error.BadValue;
    if (@as(u64, width) * height > decoded.max_pixels) return error.BadValue;
    if (format == .yuyv and width % 2 != 0) return error.BadValue;
    return .{ .path = head[0..middle], .width = width, .height = height, .format = format };
}

/// Fill `out` (width * lines pixels, three bytes each) from one whole
/// frame's `bytes`.
pub fn toRgb(format: Format, bytes: []const u8, out: []u8) void {
    switch (format) {
        .rgb24 => @memcpy(out, bytes[0..out.len]),
        .rgb565 => for (0..out.len / 3) |at| {
            out[at * 3 ..][0..3].* = fromRgb565(std.mem.readInt(u16, bytes[at * 2 ..][0..2], .little));
        },
        .yuyv => yuyvToRgb(bytes, out),
    }
}

/// Y0 U Y1 V: each pair of pixels shares one chroma sample.
fn yuyvToRgb(bytes: []const u8, out: []u8) void {
    var pair: usize = 0;
    while (pair * 6 < out.len) : (pair += 1) {
        const quad = bytes[pair * 4 ..][0..4];
        out[pair * 6 ..][0..3].* = yuv.rgb(quad[0], quad[1], quad[3]);
        out[pair * 6 + 3 ..][0..3].* = yuv.rgb(quad[2], quad[1], quad[3]);
    }
}

/// Widen 5:6:5 to 8 bits a channel, repeating the top bits into the bottom.
fn fromRgb565(value: u16) decoded.Rgb {
    const r: u8 = @intCast(value >> 11);
    const g: u8 = @intCast((value >> 5) & 0x3F);
    const b: u8 = @intCast(value & 0x1F);
    return .{ r << 3 | r >> 2, g << 2 | g >> 4, b << 3 | b >> 2 };
}
