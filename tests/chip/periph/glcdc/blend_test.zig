//! Covers src/chip/periph/glcdc/blend.zig: what each graphics layer contributes
//! to the panel, and what happens where two of them overlap.
const std = @import("std");
const ra8 = @import("ra8");

const blend = ra8.chip.periph.glcdc.blend;

fn layer() blend.Layer {
    var stage = blend.Layer{};
    // Driven, displayed, a 4x4 rectangle at the panel origin.
    stage.ab1 = blend.field.grcdispon | @backingInt(blend.Display.shown);
    stage.ab2 = 4;
    stage.ab3 = 4;
    return stage;
}

test "a size and position pair unpacks into a rectangle" {
    const rect = blend.Rect.fromPair(
        (3 << blend.field.start_shift) | 10,
        (5 << blend.field.start_shift) | 20,
    );
    try std.testing.expectEqual(@as(u32, 5), rect.left);
    try std.testing.expectEqual(@as(u32, 3), rect.top);
    try std.testing.expectEqual(@as(u32, 20), rect.width);
    try std.testing.expectEqual(@as(u32, 10), rect.height);
}

test "a zero-sized rectangle covers nothing" {
    const rect = blend.Rect{ .left = 0, .top = 0, .width = 0, .height = 4 };
    try std.testing.expect(!rect.covers(0, 0));
}

test "a rectangle covers its own span and stops at the edge" {
    const rect = blend.Rect{ .left = 2, .top = 1, .width = 3, .height = 2 };
    try std.testing.expect(rect.covers(2, 1));
    try std.testing.expect(rect.covers(4, 2));
    try std.testing.expect(!rect.covers(5, 2));
    try std.testing.expect(!rect.covers(4, 3));
    try std.testing.expect(!rect.covers(1, 1));
}

test "AB1 decodes into the display mode the driver wrote" {
    var stage = blend.Layer{};
    stage.ab1 = 3;
    try std.testing.expectEqual(blend.Display.blended, stage.display());
    stage.ab1 = 1;
    try std.testing.expectEqual(blend.Display.transparent, stage.display());
    stage.ab1 = 2 | blend.field.grcdispon;
    try std.testing.expectEqual(blend.Display.shown, stage.display());
    try std.testing.expect(stage.framed());
}

test "a layer with no frame line still shows: GRCDISPON never gates it" {
    var stage = layer();
    stage.ab1 &= ~blend.field.grcdispon;
    try std.testing.expectEqual(@as(?u32, 0xFF00_FF00), stage.contribution(0xFF00_FF00, 0, 0));
}

test "ARCDEF sits in AB7 [23:16], where ra8_glcdc_layer.c writes it" {
    var stage = layer();
    stage.ab7 = 0x80 << 16;
    try std.testing.expectEqual(@as(u32, 0x80), stage.defaultAlpha());
}

test "a transparent layer stands aside and the miss is counted" {
    var stage = layer();
    stage.ab1 = blend.field.grcdispon | @backingInt(blend.Display.transparent);
    try std.testing.expectEqual(@as(?u32, null), stage.contribution(0xFF00_FF00, 1, 1));
    try std.testing.expectEqual(@as(u32, 1), stage.hidden);
    try std.testing.expectEqual(@as(u32, 0), stage.shown);
}

test "outside its rectangle a layer contributes nothing at all" {
    var stage = layer();
    try std.testing.expectEqual(@as(?u32, null), stage.contribution(0xFF00_FF00, 9, 0));
    try std.testing.expectEqual(@as(u32, 0), stage.hidden);
}

test "a displayed layer hands back its pixel fully opaque" {
    var stage = layer();
    const shown = stage.contribution(0x0012_3456, 0, 0).?;
    try std.testing.expectEqual(@as(u32, 0xFF12_3456), shown);
    try std.testing.expectEqual(@as(u32, 1), stage.shown);
}

test "a blended layer keeps the alpha its own pixel carries" {
    var stage = layer();
    stage.ab1 = blend.field.grcdispon | @backingInt(blend.Display.blended);
    const shown = stage.contribution(0x8012_3456, 0, 0).?;
    try std.testing.expectEqual(@as(u32, 0x8012_3456), shown);
}

test "a blended pixel with no alpha of its own takes ARCDEF" {
    var stage = layer();
    stage.ab1 = blend.field.grcdispon | @backingInt(blend.Display.blended);
    stage.ab7 = 0x40 << blend.field.arcdef_shift;
    const shown = stage.contribution(0x0012_3456, 0, 0).?;
    try std.testing.expectEqual(@as(u32, 0x4012_3456), shown);
}

test "a fully transparent blended pixel drops out and is counted hidden" {
    var stage = layer();
    stage.ab1 = blend.field.grcdispon | @backingInt(blend.Display.blended);
    try std.testing.expectEqual(@as(?u32, null), stage.contribution(0x0012_3456, 0, 0));
    try std.testing.expectEqual(@as(u32, 1), stage.hidden);
}

test "the alpha rectangle applies ARCDEF where it covers, and only there" {
    var stage = layer();
    stage.ab1 = blend.field.grcdispon | blend.field.arcon | @backingInt(blend.Display.blended);
    stage.ab7 = 0x20 << blend.field.arcdef_shift;
    // A 1x1 alpha rectangle at the origin.
    stage.ab4 = 1;
    stage.ab5 = 1;
    try std.testing.expectEqual(@as(u32, 0x2012_3456), stage.contribution(0xFF12_3456, 0, 0).?);
    try std.testing.expectEqual(@as(u32, 0xFF12_3456), stage.contribution(0xFF12_3456, 1, 1).?);
}

test "a keyed pixel becomes the replacement colour and is counted" {
    var stage = layer();
    stage.ab7 = blend.field.ckon;
    stage.ab8 = 0x0012_3456;
    stage.ab9 = 0xFFAA_BBCC;
    try std.testing.expectEqual(@as(u32, 0xFFAA_BBCC), stage.contribution(0xFF12_3456, 0, 0).?);
    try std.testing.expectEqual(@as(u32, 1), stage.keyed);
    // A colour that is not the key is left alone.
    try std.testing.expectEqual(@as(u32, 0xFF99_9999), stage.contribution(0x0099_9999, 1, 0).?);
    try std.testing.expectEqual(@as(u32, 1), stage.keyed);
}

test "chroma keying off leaves the key colour alone" {
    var stage = layer();
    stage.ab8 = 0x0012_3456;
    stage.ab9 = 0xFFAA_BBCC;
    try std.testing.expectEqual(@as(u32, 0xFF12_3456), stage.contribution(0xFF12_3456, 0, 0).?);
    try std.testing.expectEqual(@as(u32, 0), stage.keyed);
}

test "a write lands in the blend register it names, and nowhere else" {
    var stage = blend.Layer{};
    try std.testing.expect(stage.latch(blend.off.ab1, 0x1234));
    try std.testing.expect(stage.latch(blend.off.base, 0x00FF_0000));
    try std.testing.expect(!stage.latch(0x0C, 0xDEAD));
    try std.testing.expectEqual(@as(u32, 0x1234), stage.ab1);
    try std.testing.expectEqual(@as(u32, 0x00FF_0000), stage.base_colour);
}

test "an unprogrammed blend stage is quiet, and the implied one is not" {
    const stage = blend.Layer{};
    try std.testing.expect(stage.quiet());
    const default = blend.implied(480, 272);
    try std.testing.expect(!default.quiet());
    try std.testing.expect(default.framed());
    try std.testing.expectEqual(blend.Display.shown, default.display());
    try std.testing.expectEqual(@as(u32, 480), default.rect().width);
    try std.testing.expectEqual(@as(u32, 272), default.rect().height);
}

test "source-over leaves an opaque top, an empty top, and blends between" {
    try std.testing.expectEqual(@as(u32, 0xFF11_2233), blend.over(0xFF11_2233, 0xFF00_0000));
    try std.testing.expectEqual(@as(u32, 0xFF44_5566), blend.over(0x0011_2233, 0xFF44_5566));
    // Half of white over black is mid grey, and the result is opaque.
    const mixed = blend.over(0x80FF_FFFF, 0xFF00_0000);
    try std.testing.expectEqual(@as(u32, 0xFF), mixed >> 24);
    try std.testing.expectEqual(@as(u32, 0x80), mixed & 0xFF);
}

test "glcdc_render's GR1 writes put a 512x512 layer at the panel origin" {
    // ra8_glcdc.c: AB3 = (h_back << 16) | fb_w, AB2 = (v_back << 16) | fb_h,
    // with the panel's back porches 160 and 23.
    var stage = layer();
    stage.ab3 = (160 << blend.field.start_shift) | 512;
    stage.ab2 = (23 << blend.field.start_shift) | 512;
    stage.origin = .{ .left = 160, .top = 23 };
    const rect = stage.rect();
    try std.testing.expectEqual(blend.Rect{ .left = 0, .top = 0, .width = 512, .height = 512 }, rect);
    try std.testing.expect(stage.rect().covers(511, 511));
    try std.testing.expect(!stage.rect().covers(512, 0));
}

test "a layer moved right sits past the origin by the difference" {
    var stage = layer();
    stage.ab3 = (224 << blend.field.start_shift) | 320;
    stage.ab2 = (55 << blend.field.start_shift) | 240;
    stage.origin = .{ .left = 160, .top = 23 };
    const rect = stage.rect();
    try std.testing.expectEqual(blend.Rect{ .left = 64, .top = 32, .width = 320, .height = 240 }, rect);
}

test "the part of a rectangle that starts in the porch is lost" {
    const rect = blend.Rect.fromPair(10 << blend.field.start_shift | 8, 100 << blend.field.start_shift | 50);
    const placed = rect.from(.{ .left = 120, .top = 12 });
    try std.testing.expectEqual(blend.Rect{ .left = 0, .top = 0, .width = 30, .height = 6 }, placed);
}

test "the implied stage ignores the origin until the driver positions it" {
    var stage = blend.implied(480, 272);
    stage.origin = .{ .left = 160, .top = 23 };
    try std.testing.expectEqual(blend.Rect{ .left = 0, .top = 0, .width = 480, .height = 272 }, stage.rect());
    _ = stage.latch(blend.off.ab3, (170 << blend.field.start_shift) | 480);
    try std.testing.expect(!stage.implicit);
    try std.testing.expectEqual(@as(u32, 10), stage.rect().left);
}

test "placeAll gives every layer the same origin" {
    var layers = [_]blend.Layer{ .{}, .{} };
    blend.placeAll(&layers, .{ .left = 160, .top = 23 });
    try std.testing.expectEqual(@as(u32, 160), layers[1].origin.left);
    try std.testing.expectEqual(@as(u32, 23), layers[0].origin.top);
}
