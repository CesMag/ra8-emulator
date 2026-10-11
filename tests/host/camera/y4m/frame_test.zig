//! Covers src/host/camera/y4m_frame.zig: BT.601 studio-range planes
//! turned into RGB, with each chroma sample covering the luma under it.
const std = @import("std");
const ra8 = @import("ra8");

const yuv = ra8.host.camera.y4m_frame;
const y4m = ra8.host.camera.y4m;

test "studio black, white and red come back as full-range RGB" {
    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, yuv.rgb(16, 128, 128));
    try std.testing.expectEqual([3]u8{ 255, 255, 255 }, yuv.rgb(235, 128, 128));
    try std.testing.expectEqual([3]u8{ 255, 0, 0 }, yuv.rgb(81, 90, 240));
}

test "a 4:2:0 frame shares one chroma sample over each 2x2 block" {
    const header = try y4m.parse("YUV4MPEG2 W2 H2 C420");
    const planes = [_]u8{ 81, 81, 81, 81, 90, 240 };
    var out: [12]u8 = undefined;
    yuv.toRgb(header, &planes, &out);
    for (0..4) |i| try std.testing.expectEqual([3]u8{ 255, 0, 0 }, out[i * 3 ..][0..3].*);
}

test "a mono frame is grey, a 4:4:4 frame has chroma per pixel" {
    const mono = try y4m.parse("YUV4MPEG2 W2 H1 Cmono");
    var grey: [6]u8 = undefined;
    yuv.toRgb(mono, &[_]u8{ 16, 235 }, &grey);
    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, grey[0..3].*);
    try std.testing.expectEqual([3]u8{ 255, 255, 255 }, grey[3..6].*);
    const full = try y4m.parse("YUV4MPEG2 W2 H1 C444");
    var colour: [6]u8 = undefined;
    yuv.toRgb(full, &[_]u8{ 81, 235, 90, 128, 240, 128 }, &colour);
    try std.testing.expectEqual([3]u8{ 255, 0, 0 }, colour[0..3].*);
    try std.testing.expectEqual([3]u8{ 255, 255, 255 }, colour[3..6].*);
}
