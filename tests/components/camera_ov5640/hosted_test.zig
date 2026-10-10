//! Covers src/components/camera_ov5640/hosted.zig: a host input wrapped as the CEU's
//! frame source, asked for its picture at each capture's emulated time and
//! converted to whatever FORMAT CONTROL says then.
const std = @import("std");
const ra8 = @import("ra8");

const camera = ra8.chip.periph.ceu.camera;
const hosted = ra8.components.camera.hosted;
const allocator = std.testing.allocator;

/// A host input with one line, red then green, that records what it is asked.
const Fake = struct {
    pixels: [6]u8 = .{ 255, 0, 0, 0, 255, 0 },
    asked: ?u64 = null,
    closed: bool = false,

    pub fn picture(self: *Fake, when: u64) ra8.components.camera.convert.Frame {
        self.asked = when;
        return .{ .width = 2, .height = 1, .pixels = &self.pixels };
    }

    pub fn close(self: *Fake) void {
        self.closed = true;
    }
};

fn open(fake: *Fake, format_control: *const u8) !camera.frame_source.FrameSource {
    return hosted.Hosted(Fake).open(allocator, fake, format_control, "fake", "fake:0");
}

test "FORMAT CONTROL picks RGB565 for 0x6x and YUV422 otherwise" {
    try std.testing.expectEqual(ra8.components.camera.convert.Format.rgb565, hosted.formatFor(0x6F));
    try std.testing.expectEqual(ra8.components.camera.convert.Format.rgb565, hosted.formatFor(0x61));
    try std.testing.expectEqual(ra8.components.camera.convert.Format.yuv422, hosted.formatFor(0x30));
    try std.testing.expectEqual(ra8.components.camera.convert.Format.yuv422, hosted.formatFor(0x00));
}

test "the format is read again at each capture" {
    var fake: Fake = .{};
    var format_control: u8 = 0x6F;
    const source = try open(&fake, &format_control);
    defer source.close();
    format_control = 0x30;
    source.frame(0, .{ .width = 4, .lines = 1 });
    var line: [4]u8 = undefined;
    source.fill(0, 0, &line);
    const red = ra8.components.camera.convert.Rgb{ .r = 255, .g = 0, .b = 0 };
    const green = ra8.components.camera.convert.Rgb{ .r = 0, .g = 255, .b = 0 };
    try std.testing.expectEqualSlices(u8, &ra8.components.camera.convert.yuyv(red, green), &line);
    format_control = 0x6F;
    source.frame(1, .{ .width = 4, .lines = 1 });
    source.fill(0, 0, &line);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0xF8, 0xE0, 0x07 }, &line);
}

test "each capture asks for the picture at its time, and closing closes the input" {
    var fake: Fake = .{};
    var format_control: u8 = 0x30;
    const source = try open(&fake, &format_control);
    try std.testing.expectEqualStrings("fake", source.label);
    try std.testing.expectEqualStrings("fake:0", source.detail);
    try std.testing.expectEqual(@as(?u64, null), fake.asked);
    source.frame(1234, .{ .width = 4, .lines = 1 });
    try std.testing.expectEqual(@as(?u64, 1234), fake.asked);
    source.close();
    try std.testing.expect(fake.closed);
}
