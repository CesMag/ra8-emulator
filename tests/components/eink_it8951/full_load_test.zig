//! RA8EMU-686: one image-load command covers the full IT8951 panel.
const std = @import("std");
const ra8 = @import("ra8");
const eink = ra8.components.eink;
const proto = ra8.components.eink.wire;

fn word(panel: *eink.Panel, value: u16) void {
    _ = panel.exchange(@intCast(value >> 8));
    _ = panel.exchange(@intCast(value & 0xFF));
}

fn command(panel: *eink.Panel, code: proto.Command) void {
    word(panel, proto.preamble.command);
    word(panel, @backingInt(code));
}

fn data(panel: *eink.Panel, value: u16) void {
    word(panel, proto.preamble.write);
    word(panel, value);
}

test "one 8 bpp load fills the full panel without wrapping its data cursor" {
    const width: u16 = 1072;
    const height: u16 = 1448;
    const pixel_count = @as(usize, width) * height;
    var panel = eink.Panel.init();
    defer panel.deinit();
    panel.planes.allocator = std.testing.allocator;
    panel.planes.resize(.{ .width = width, .height = height });

    command(&panel, .load_area);
    data(&panel, 0x0030);
    data(&panel, 0);
    data(&panel, 0);
    data(&panel, width);
    data(&panel, height);
    for (0..pixel_count / 2) |pair| {
        const first: u8 = @truncate(pair * 2 *% 37 +% 11);
        const second: u8 = @truncate((pair * 2 + 1) *% 37 +% 11);
        data(&panel, @as(u16, second) << 8 | first);
    }

    for (0..pixel_count) |index| {
        const expected: u8 = @truncate(index *% 37 +% 11);
        try std.testing.expectEqual(expected, panel.planes.image.pixels[index]);
    }
    try std.testing.expectEqual(@as(u32, 0), panel.overrun);
    try std.testing.expectEqual(@as(u32, 0), panel.stray);
    try std.testing.expectEqual(@as(u32, 0), panel.asleep);
}
