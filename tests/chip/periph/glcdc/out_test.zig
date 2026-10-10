//! Tests for the GLCDC output stage.
const std = @import("std");
const ra8 = @import("ra8");
const out = ra8.chip.periph.glcdc.out;
const gam = ra8.chip.periph.glcdc.gamma;

const white: u32 = 0xFF_FF_FF_FF;
const grey: u32 = 0xFF_80_80_80;

fn commit(stage: *out.Stage) void {
    _ = stage.latch(out.off.vlatch, out.field.ven);
}

fn setFormat(stage: *out.Stage, format: out.Format) void {
    const code: u32 = @backingInt(format);
    _ = stage.latch(out.off.set, code << out.field.format_shift);
    commit(stage);
}

test "the stage owns its own offsets and nothing else" {
    try std.testing.expect(out.owns(out.off.set));
    try std.testing.expect(out.owns(out.off.gamsw));
    try std.testing.expect(out.owns(0x1300));
    try std.testing.expect(!out.owns(0x1100));
    try std.testing.expect(!out.owns(0x1014));
}

test "a fresh stage is quiet and its defaults are identity" {
    var stage = out.Stage{};
    try std.testing.expect(stage.quiet());
    try std.testing.expectEqual(out.Format.rgb888, stage.live.format());
    try std.testing.expectEqual(grey, stage.apply(grey, 0, 0));
    try std.testing.expect(!stage.quiet());
}

test "a shadow write is pending until vlatch commits it" {
    var stage = out.Stage{};
    _ = stage.latch(out.off.set, @as(u32, @backingInt(out.Format.rgb565)) << out.field.format_shift);
    try std.testing.expect(stage.pending());
    // The panel is still driven from the old format.
    try std.testing.expectEqual(out.Format.rgb888, stage.live.format());
    commit(&stage);
    try std.testing.expect(!stage.pending());
    try std.testing.expectEqual(out.Format.rgb565, stage.live.format());
    try std.testing.expectEqual(@as(u32, 1), stage.commits);
}

test "a vlatch without ven commits nothing" {
    var stage = out.Stage{};
    _ = stage.latch(out.off.contrast, 0);
    _ = stage.latch(out.off.vlatch, 0);
    try std.testing.expect(stage.pending());
}

test "rgb565 drops the low bits of every channel" {
    var stage = out.Stage{};
    setFormat(&stage, out.Format.rgb565);
    const result = stage.apply(0xFF_1F_1F_1F, 0, 0);
    try std.testing.expectEqual(@as(u32, 0x18), result >> 16 & 0xFF);
    try std.testing.expectEqual(@as(u32, 0x1C), result >> 8 & 0xFF);
    try std.testing.expectEqual(@as(u32, 0x18), result & 0xFF);
    try std.testing.expectEqual(@as(u32, 1), stage.narrowed);
}

test "rgb666 keeps six bits per channel" {
    var stage = out.Stage{};
    setFormat(&stage, out.Format.rgb666);
    const result = stage.apply(0xFF_FF_FF_FF, 0, 0);
    try std.testing.expectEqual(@as(u32, 0xFC), result >> 16 & 0xFF);
}

test "rgb888 carries the pixel through untouched" {
    var stage = out.Stage{};
    setFormat(&stage, out.Format.rgb888);
    try std.testing.expectEqual(0xFF_12_34_56, stage.apply(0xFF_12_34_56, 0, 0));
    try std.testing.expectEqual(@as(u32, 0), stage.narrowed);
}

test "alpha is not an output channel and survives" {
    var stage = out.Stage{};
    setFormat(&stage, out.Format.rgb565);
    const result = stage.apply(0x7F_80_80_80, 3, 5);
    try std.testing.expectEqual(@as(u32, 0x7F), result >> 24);
}

test "the dither pattern moves pixels by their position" {
    var stage = out.Stage{};
    _ = stage.latch(out.off.set, @as(u32, @backingInt(out.Format.rgb565)) << out.field.format_shift);
    const sel: u32 = @as(u32, @backingInt(out.Dither.pattern)) << out.field.dither_shift;
    // PA=0, PB=3, PC=0, PD=3 across the 2x2 cell.
    _ = stage.latch(out.off.pdtha, sel | (3 << 2) | (3 << 6));
    commit(&stage);
    const even = stage.apply(0xFF_1E_1E_1E, 0, 0);
    const odd = stage.apply(0xFF_1E_1E_1E, 1, 0);
    try std.testing.expect(even != odd);
    try std.testing.expectEqual(@as(u32, 1), stage.dithered);
}

test "truncation does not dither" {
    var stage = out.Stage{};
    _ = stage.latch(out.off.set, @as(u32, @backingInt(out.Format.rgb565)) << out.field.format_shift);
    _ = stage.latch(out.off.pdtha, @as(u32, @backingInt(out.Dither.truncate)) << out.field.dither_shift);
    commit(&stage);
    _ = stage.apply(0xFF_10_10_10, 1, 1);
    try std.testing.expectEqual(@as(u32, 0), stage.dithered);
}

test "contrast below unity darkens the pixel" {
    var stage = out.Stage{};
    const half = out.field.contrast_unity / 2;
    _ = stage.latch(out.off.contrast, half << out.field.green_shift | half << out.field.blue_shift | half);
    commit(&stage);
    const result = stage.apply(grey, 0, 0);
    try std.testing.expectEqual(@as(u32, 0x40), result & 0xFF);
}

test "brightness above mid-scale lifts the pixel" {
    var stage = out.Stage{};
    const lift = out.field.bright_mid + 128;
    _ = stage.latch(out.off.bright1, lift);
    _ = stage.latch(out.off.bright2, lift << out.field.green_shift | lift);
    commit(&stage);
    const result = stage.apply(grey, 0, 0);
    try std.testing.expectEqual(@as(u32, 0xA0), result & 0xFF);
}

test "a pixel driven past white is counted as clipped" {
    var stage = out.Stage{};
    const lift = out.field.bright_mid + 400;
    _ = stage.latch(out.off.bright1, lift);
    _ = stage.latch(out.off.bright2, lift << out.field.green_shift | lift);
    commit(&stage);
    const result = stage.apply(white, 0, 0);
    try std.testing.expectEqual(@as(u32, 0xFF), result & 0xFF);
    try std.testing.expectEqual(@as(u32, 1), stage.clipped);
}

test "the brightness fields are read per channel" {
    var stage = out.Stage{};
    _ = stage.latch(out.off.bright1, out.field.bright_mid + 4);
    _ = stage.latch(out.off.bright2, (out.field.bright_mid + 8) << out.field.green_shift |
        (out.field.bright_mid + 12));
    commit(&stage);
    const offsets = stage.live.brightness();
    try std.testing.expectEqual(@as(i32, 12), offsets[0]);
    try std.testing.expectEqual(@as(i32, 4), offsets[1]);
    try std.testing.expectEqual(@as(i32, 8), offsets[2]);
}

test "gamon with no table programmed leaves the pixel alone" {
    var stage = out.Stage{};
    _ = stage.latch(out.off.gamsw, out.field.gamon);
    try std.testing.expect(stage.gamma_on);
    try std.testing.expectEqual(grey, stage.apply(grey, 0, 0));
    try std.testing.expectEqual(@as(u32, 0), stage.corrected);
}

test "a programmed gamma curve corrects the pixel" {
    var stage = out.Stage{};
    var index: u32 = 0;
    while (index < gam.geometry.registers) : (index += 1) {
        const half = gam.field.unity / 2;
        _ = stage.latch(0x1300 + index * 4, half << gam.field.gain_shift | half);
    }
    _ = stage.latch(out.off.gamsw, out.field.gamon);
    const result = stage.apply(grey, 0, 0);
    try std.testing.expectEqual(@as(u32, 0x40), result >> 16 & 0xFF);
    // Green and blue were not programmed, so they pass through.
    try std.testing.expectEqual(@as(u32, 0x80), result >> 8 & 0xFF);
    try std.testing.expectEqual(@as(u32, 1), stage.corrected);
}

test "a gamma write reaches the channel its offset names" {
    var stage = out.Stage{};
    _ = stage.latch(0x1380 + gam.geometry.area_base, 0x0010_0020);
    try std.testing.expect(stage.gamma[2].programmed);
    try std.testing.expect(!stage.gamma[0].programmed);
}

test "gamsw is not shadowed, so it needs no vlatch" {
    var stage = out.Stage{};
    _ = stage.latch(out.off.gamsw, out.field.gamon);
    try std.testing.expect(!stage.pending());
    try std.testing.expect(stage.gamma_on);
}

test "clkphase is taken and changes nothing about a pixel" {
    var stage = out.Stage{};
    try std.testing.expect(stage.latch(out.off.clkphase, 0));
    try std.testing.expectEqual(grey, stage.apply(grey, 0, 0));
}

test "an offset the stage does not own is refused" {
    var stage = out.Stage{};
    try std.testing.expect(!stage.latch(0x1100, 1));
    try std.testing.expectEqual(@as(u32, 0), stage.writes);
}

test "every pixel through the stage is counted" {
    var stage = out.Stage{};
    setFormat(&stage, out.Format.rgb565);
    _ = stage.apply(grey, 0, 0);
    _ = stage.apply(grey, 1, 0);
    try std.testing.expectEqual(@as(u32, 2), stage.pixels);
}

test "an armed capture keeps exactly what leaves the stage and drops what falls outside it" {
    var stage = out.Stage{};
    var pixels = @as([4]u32, @splat(0));
    stage.capture = .{ .pixels = &pixels, .width = 2, .height = 2 };
    const shown = stage.apply(grey, 1, 1);
    try std.testing.expectEqual(shown, pixels[3]);
    _ = stage.apply(white, 2, 0);
    _ = stage.apply(white, 0, 2);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 0, 0, 0, shown }, &pixels);
    stage.capture = null;
    _ = stage.apply(white, 0, 0);
    try std.testing.expectEqual(@as(u32, 0), pixels[0]);
}

test {
    _ = @import("vsync_test.zig");
}
