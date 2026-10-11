//! Covers src/host/camera/mf_abi.zig: the Media Foundation GUIDs,
//! frame-size packing and vtable slots the Windows webcam reader uses.
const std = @import("std");
const ra8 = @import("ra8");
const mf = ra8.host.camera.mf;

test "the video subtypes share the FourCC base GUID" {
    try std.testing.expectEqual(@as(u32, 0x32595559), mf.format_yuy2.Data1);
    try std.testing.expectEqual(@as(u32, 0x16), mf.format_rgb32.Data1);
    try std.testing.expectEqual(@as(u32, 0x73646976), mf.media_type_video.Data1);
    const base = [8]u8{ 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 };
    for ([_]mf.Guid{ mf.format_yuy2, mf.format_rgb32, mf.media_type_video }) |g| {
        try std.testing.expectEqual(@as(u16, 0x0000), g.Data2);
        try std.testing.expectEqual(@as(u16, 0x0010), g.Data3);
        try std.testing.expectEqualSlices(u8, &base, &g.Data4);
    }
}

test "attribute keys parse to the documented bytes" {
    try std.testing.expectEqual(@as(u32, 0x1652c33d), mf.mt_frame_size.Data1);
    try std.testing.expectEqual(@as(u16, 0xd6b2), mf.mt_frame_size.Data2);
    try std.testing.expectEqualSlices(u8, &.{ 0xb8, 0x34, 0x72, 0x03, 0x08, 0x49, 0xa3, 0x7d }, &mf.mt_frame_size.Data4);
    try std.testing.expectEqual(@as(u32, 0x8ac3587a), mf.devsource_vidcap.Data1);
    try std.testing.expectEqual(@as(u32, 0x279a808d), mf.iid_media_source.Data1);
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(mf.Guid));
}

test "frame size packs width over height and back" {
    try std.testing.expectEqual(@as(u64, 0x0000_0280_0000_01e0), mf.packSize(640, 480));
    const size = mf.unpackSize(mf.packSize(1920, 1080));
    try std.testing.expectEqual(@as(u32, 1920), size.width);
    try std.testing.expectEqual(@as(u32, 1080), size.height);
}

test "slots past IMFAttributes start after its 33 entries" {
    try std.testing.expectEqual(@as(usize, 33), mf.slot.activate_object);
    try std.testing.expectEqual(@as(usize, 33 + 8), mf.slot.sample_to_contiguous);
    try std.testing.expect(mf.succeeded(0) and mf.succeeded(1) and !mf.succeeded(-2147024891));
}
