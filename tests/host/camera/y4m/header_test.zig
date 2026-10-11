//! Covers src/host/camera/y4m_header.zig: the stream header's tags, the
//! Y4M defaults, what is refused, and the bytes one frame takes.
const std = @import("std");
const ra8 = @import("ra8");

const y4m = ra8.host.camera.y4m;

test "the size, rate and chroma tags are read" {
    const header = try y4m.parse("YUV4MPEG2 W640 H480 F30000:1001 Ip A1:1 C420jpeg XYSCSS=420JPEG");
    try std.testing.expectEqual(@as(u32, 640), header.width);
    try std.testing.expectEqual(@as(u32, 480), header.height);
    try std.testing.expectEqual(@as(u32, 30000), header.fps_num);
    try std.testing.expectEqual(@as(u32, 1001), header.fps_den);
    try std.testing.expectEqual(y4m.Chroma.c420, header.chroma);
}

test "with no F or C tag the rate is 25:1 and the chroma 4:2:0" {
    const header = try y4m.parse("YUV4MPEG2 W2 H2");
    try std.testing.expectEqual(@as(u32, 25), header.fps_num);
    try std.testing.expectEqual(@as(u32, 1), header.fps_den);
    try std.testing.expectEqual(y4m.Chroma.c420, header.chroma);
}

test "a header that is not Y4M, has no size, or a zero rate is refused" {
    try std.testing.expectError(error.BadHeader, y4m.parse("P6 W2 H2"));
    try std.testing.expectError(error.BadHeader, y4m.parse("YUV4MPEG2 W2"));
    try std.testing.expectError(error.BadHeader, y4m.parse("YUV4MPEG2 W2 H2 F0:1"));
    try std.testing.expectError(error.BadHeader, y4m.parse("YUV4MPEG2 Wx H2"));
}

test "interlaced and deeper-than-8-bit streams are refused, not guessed at" {
    try std.testing.expectError(error.Unsupported, y4m.parse("YUV4MPEG2 W2 H2 It"));
    try std.testing.expectError(error.Unsupported, y4m.parse("YUV4MPEG2 W2 H2 C420p10"));
    try std.testing.expectError(error.Unsupported, y4m.parse("YUV4MPEG2 W2 H2 C444alpha"));
}

test "one frame's bytes follow the chroma layout, odd sizes rounded up" {
    try std.testing.expectEqual(@as(u64, 15 + 2 * 6), (try y4m.parse("YUV4MPEG2 W5 H3 C420")).frameBytes());
    try std.testing.expectEqual(@as(u64, 15 + 2 * 9), (try y4m.parse("YUV4MPEG2 W5 H3 C422")).frameBytes());
    try std.testing.expectEqual(@as(u64, 15 * 3), (try y4m.parse("YUV4MPEG2 W5 H3 C444")).frameBytes());
    try std.testing.expectEqual(@as(u64, 15), (try y4m.parse("YUV4MPEG2 W5 H3 Cmono")).frameBytes());
}
