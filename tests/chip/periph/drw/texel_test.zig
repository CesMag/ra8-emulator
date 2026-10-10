//! Covers src/chip/periph/drw/texel.zig: the READFORMAT table, the widths it
//! gives a texel, and the ARGB8888 colour a raw texel means.
const std = @import("std");
const ra8 = @import("ra8");

const texel = ra8.chip.periph.drw_texel;
const tex = ra8.chip.periph.drw_tex;

fn readFormat(code: u32) u32 {
    const high = code >> texel.field.high_position & texel.field.high_mask;
    const low = code & texel.field.low_mask;
    return high << texel.field.high_shift | low << texel.field.low_shift;
}

test "READFORMAT is reassembled from its two CONTROL2 halves" {
    try std.testing.expectEqual(texel.Format.a8, texel.Format.decode(0));
    try std.testing.expectEqual(texel.Format.argb8888, texel.Format.decode(readFormat(0x2)));
    try std.testing.expectEqual(texel.Format.argb1555, texel.Format.decode(readFormat(0x4)));
    try std.testing.expectEqual(texel.Format.clut4, texel.Format.decode(readFormat(0xA)));
}

test "the format halves do not collide with the blend bits between them" {
    const word = readFormat(0x9) | tex.control2.clut_enable | tex.control2.colkey_enable;
    try std.testing.expectEqual(texel.Format.clut8, texel.Format.decode(word));
}

test "every documented format has a width and the undocumented ones do not" {
    try std.testing.expectEqual(@as(?u32, 8), texel.Format.a8.bits());
    try std.testing.expectEqual(@as(?u32, 16), texel.Format.rgb565.bits());
    try std.testing.expectEqual(@as(?u32, 32), texel.Format.argb8888.bits());
    try std.testing.expectEqual(@as(?u32, 4), texel.Format.clut4.bits());
    try std.testing.expectEqual(@as(?u32, 1), texel.Format.clut1.bits());
    try std.testing.expectEqual(@as(?u32, null), texel.Format.decode(readFormat(0x7)).bits());
    try std.testing.expectEqual(@as(?u32, null), texel.Format.decode(readFormat(0xF)).bits());
}

test "only the CLUT formats are indexed" {
    try std.testing.expect(texel.Format.clut1.indexed());
    try std.testing.expect(texel.Format.aclut44.indexed());
    try std.testing.expect(!texel.Format.argb4444.indexed());
    try std.testing.expect(!texel.Format.a8.indexed());
}

test "ACLUT44 indexes with the low nibble and carries its own alpha" {
    try std.testing.expectEqual(@as(u32, 0x3), texel.Format.aclut44.index(0xF3));
    try std.testing.expectEqual(@as(?u32, 0xFF), texel.Format.aclut44.carriedAlpha(0xF3));
    try std.testing.expectEqual(@as(?u32, 0), texel.Format.aclut44.carriedAlpha(0x03));
    try std.testing.expectEqual(@as(?u32, null), texel.Format.clut8.carriedAlpha(0x7F));
    try std.testing.expectEqual(@as(u32, 0x7F), texel.Format.clut8.index(0x7F));
}

test "A8 is alpha alone, with no colour under it" {
    try std.testing.expectEqual(@as(u32, 0xFF00_0000), texel.Format.a8.expand(0xFF));
    try std.testing.expectEqual(@as(u32, 0), texel.Format.a8.expand(0));
}

test "ARGB8888 passes through and ARGB4444 widens each nibble" {
    try std.testing.expectEqual(@as(u32, 0x1234_5678), texel.Format.argb8888.expand(0x1234_5678));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), texel.expand4444(0xFFFF));
    try std.testing.expectEqual(@as(u32, 0xFF00_0000), texel.expand4444(0xF000));
    try std.testing.expectEqual(@as(u32, 0x8888_8888), texel.expand4444(0x8888));
}

test "ARGB1555 alpha is one bit, on or off" {
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), texel.expand1555(0xFFFF));
    try std.testing.expectEqual(@as(u32, 0x00FF_FFFF), texel.expand1555(0x7FFF));
    try std.testing.expectEqual(@as(u32, 0xFF00_0000), texel.expand1555(0x8000));
}

test "a texel's bit offset is its index times its width" {
    try std.testing.expectEqual(@as(u64, 0), texel.bitOffset(4, 0));
    try std.testing.expectEqual(@as(u64, 12), texel.bitOffset(4, 3));
    try std.testing.expectEqual(@as(u64, 96), texel.bitOffset(32, 3));
}

test "extract pulls the right field out of the bytes that hold it" {
    const bytes = [_]u8{ 0x78, 0x56, 0x34, 0x12 };
    try std.testing.expectEqual(@as(u32, 0x1234_5678), texel.extract(32, 0, bytes));
    try std.testing.expectEqual(@as(u32, 0x5678), texel.extract(16, 0, bytes));
    try std.testing.expectEqual(@as(u32, 0x78), texel.extract(8, 0, bytes));
    try std.testing.expectEqual(@as(u32, 0x8), texel.extract(4, 0, bytes));
    try std.testing.expectEqual(@as(u32, 0x7), texel.extract(4, 4, bytes));
    try std.testing.expectEqual(@as(u32, 0), texel.extract(1, 0, bytes));
    try std.testing.expectEqual(@as(u32, 1), texel.extract(1, 3, bytes));
    try std.testing.expectEqual(@as(u32, 3), texel.extract(2, 4, bytes));
    try std.testing.expectEqual(@as(u32, 0), texel.extract(2, 0, bytes));
}
