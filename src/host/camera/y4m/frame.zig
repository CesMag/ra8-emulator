//! One Y4M frame's planes as 8-bit RGB (RA8EMU-499).
//!
//! The planes are read as BT.601 studio range (Y 16..235, chroma centred on
//! 128), which is what ffmpeg writes to a yuv4mpegpipe by default and the
//! inverse of the YUV422 the converter hands the firmware. Chroma is
//! sampled at the pixel's own position, so 4:2:0 and 4:2:2 repeat each
//! chroma sample over the luma it covers.
const decoded = @import("../decoded_image.zig");
const header = @import("header.zig");

/// Fill `out` (width * height pixels, three bytes each) from `planes`
/// (header.frameBytes()).
pub fn toRgb(h: header.Header, planes: []const u8, out: []u8) void {
    const chroma = h.chromaSize();
    const luma_bytes = @as(usize, h.width) * h.height;
    const chroma_bytes = @as(usize, chroma.width) * chroma.height;
    var y: u32 = 0;
    while (y < h.height) : (y += 1) {
        var x: u32 = 0;
        while (x < h.width) : (x += 1) {
            const luma = planes[@as(usize, y) * h.width + x];
            var u: u8 = 128;
            var v: u8 = 128;
            if (h.chroma != .mono) {
                const cx = x * chroma.width / h.width;
                const cy = y * chroma.height / h.height;
                const at = @as(usize, cy) * chroma.width + cx;
                u = planes[luma_bytes + at];
                v = planes[luma_bytes + chroma_bytes + at];
            }
            const pixel = @as(usize, y) * h.width + x;
            out[pixel * 3 ..][0..3].* = rgb(luma, u, v);
        }
    }
}

/// BT.601 studio-range YUV to RGB, in fixed point.
pub fn rgb(luma: u8, u: u8, v: u8) decoded.Rgb {
    const c: i32 = @as(i32, luma) - 16;
    const d: i32 = @as(i32, u) - 128;
    const e: i32 = @as(i32, v) - 128;
    return .{
        clamp((298 * c + 409 * e + 128) >> 8),
        clamp((298 * c - 100 * d - 208 * e + 128) >> 8),
        clamp((298 * c + 516 * d + 128) >> 8),
    };
}

fn clamp(value: i32) u8 {
    return @intCast(@max(0, @min(255, value)));
}
