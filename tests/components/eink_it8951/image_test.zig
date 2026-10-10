//! The e-ink planes: allocated at the panel geometry on first use and
//! clipping writes outside it.
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

fn openLoad(panel: *eink.Panel, width: u16, height: u16) void {
    command(panel, .load_area);
    data(panel, 0x0030);
    data(panel, 0);
    data(panel, 0);
    data(panel, width);
    data(panel, height);
}

fn refresh(panel: *eink.Panel, width: u16, height: u16, mode: u16) void {
    command(panel, .display_area);
    data(panel, 0);
    data(panel, 0);
    data(panel, width);
    data(panel, height);
    data(panel, mode);
}

test "the image plane clips writes outside the default 1072x1448 panel" {
    var panel = eink.Panel.init();
    panel.planes.allocator = std.testing.allocator;
    defer panel.deinit();
    try std.testing.expect(panel.planes.ready());
    panel.planes.image.set(1071, 1447, 0x55);
    panel.planes.image.set(1072, 0, 0xAA);
    panel.planes.image.set(0, 1448, 0xAA);
    try std.testing.expectEqual(@as(u8, 0x55), panel.planes.image.pixel(1071, 1447));
    try std.testing.expectEqual(@as(u8, 0), panel.planes.image.pixel(1072, 0));
    try std.testing.expectEqual(@as(usize, 1072 * 1448), panel.planes.glass.pixels.len);
}

test "a resized panel allocates and clips at its own geometry" {
    var panel = eink.Panel.init();
    panel.planes.allocator = std.testing.allocator;
    defer panel.deinit();
    panel.planes.resize(try proto.Geometry.parse("16x8"));
    try std.testing.expect(panel.planes.ready());
    panel.planes.image.set(15, 7, 9);
    panel.planes.image.set(16, 0, 9);
    try std.testing.expectEqual(@as(u8, 9), panel.planes.image.pixel(15, 7));
    try std.testing.expectEqual(@as(usize, 128), panel.planes.image.pixels.len);
    panel.planes.resize(.{});
    try std.testing.expectEqual(@as(usize, 0), panel.planes.image.pixels.len);
}

test "DU and both A2 LUT modes quantize to black and white over the blank glass" {
    const modes = [_]u16{ proto.waveform.du, proto.waveform.a2_m641, proto.waveform.a2_generic };
    for (modes) |mode| {
        var panel = eink.Panel.init();
        defer panel.deinit();
        openLoad(&panel, 4, 1);
        data(&panel, 0x407F);
        data(&panel, 0x80FF);
        refresh(&panel, 4, 1, mode);
        // The glass starts black, so the white pair flips and keeps an
        // eighth of the old black as residue (RA8EMU-559).
        const expected = [_]u8{ 0, 0, 0xE0, 0xE0 };
        for (expected, 0..) |value, x| {
            try std.testing.expectEqual(value, panel.planes.glass.pixel(@intCast(x), 0));
        }
    }
}

test "GC16 refresh preserves sixteen distinct grey levels" {
    var panel = eink.Panel.init();
    defer panel.deinit();
    openLoad(&panel, 16, 1);
    for (0..8) |pair| {
        const low: u16 = @intCast(pair * 2 * 17);
        const high: u16 = @intCast((pair * 2 + 1) * 17);
        data(&panel, low | (high << 8));
    }
    refresh(&panel, 16, 1, proto.waveform.gc16);
    for (0..16) |index| {
        try std.testing.expectEqual(@as(u8, @intCast(index * 17)), panel.planes.glass.pixel(@intCast(index), 0));
    }
}

test "INIT refresh clears its rectangle to white" {
    var panel = eink.Panel.init();
    defer panel.deinit();
    openLoad(&panel, 2, 1);
    data(&panel, 0x2412);
    refresh(&panel, 1, 1, proto.waveform.init);
    try std.testing.expectEqual(@as(u8, 0xFF), panel.planes.glass.pixel(0, 0));
    try std.testing.expectEqual(@as(u8, 0), panel.planes.glass.pixel(1, 0));
}

test "planes that cannot be allocated drop the write and count it" {
    var panel = eink.Panel.init();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    panel.planes.allocator = failing.allocator();
    defer panel.deinit();
    try std.testing.expect(!panel.planes.ready());
    try std.testing.expectEqual(@as(u32, 1), panel.planes.unplaced);
    try std.testing.expectEqual(@as(usize, 0), panel.planes.image.pixels.len);
}
