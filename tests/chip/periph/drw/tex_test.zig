//! Covers src/chip/periph/drw/tex.zig: the U/V generators, the mask that folds a
//! coordinate back into the texture, the palette path, the colour key, and
//! the configurations this model refuses to sample rather than guess at.
const std = @import("std");
const ra8 = @import("ra8");

const tex = ra8.chip.periph.drw_tex;
const texel = ra8.chip.periph.drw_texel;
const store_memory = @import("../store_memory.zig");
const Guest = store_memory.Guest;

/// An SRAM address a texture can live at, which memmap.initiatorHolds admits.
const tex_base: u32 = 0x2200_0000;

fn readFormat(code: u32) u32 {
    const high = code >> texel.field.high_position & texel.field.high_mask;
    const low = code & texel.field.low_mask;
    return high << texel.field.high_shift | low << texel.field.low_shift;
}

/// A source with a texture programmed: 8x8 texels, origin in SRAM, and the
/// masks that make a coordinate outside it wrap.
fn programmed() tex.Source {
    var source = tex.Source{};
    _ = source.latch(tex.off.texorigin, tex_base);
    _ = source.latch(tex.off.texpitch, 8);
    _ = source.latch(tex.off.texmask, 7 << 16 | 7);
    return source;
}

test "the texture registers latch and every other offset is left alone" {
    var source = tex.Source{};
    try std.testing.expect(source.latch(tex.off.lustart, 0x10));
    try std.testing.expect(source.latch(tex.off.texpitch, 64));
    try std.testing.expect(source.latch(tex.off.colkey, 0x00FF_00FF));
    try std.testing.expect(!source.latch(0x064, 0xFFFF_FFFF));
    try std.testing.expectEqual(@as(i32, 0x10), source.lustart);
    try std.testing.expectEqual(@as(u32, 64), source.texpitch);
    try std.testing.expectEqual(@as(u32, 0x00FF_00FF), source.colkey);
}

test "U is sub-pixel: sixteen steps of LUXADD move one texel" {
    var source = tex.Source{};
    _ = source.latch(tex.off.luxadd, 1);
    _ = source.latch(tex.off.luyadd, 16);
    try std.testing.expectEqual(@as(i64, 0), source.coordinate(15, 0).u);
    try std.testing.expectEqual(@as(i64, 1), source.coordinate(16, 0).u);
    try std.testing.expectEqual(@as(i64, 3), source.coordinate(0, 3).u);
}

test "a negative U start stays negative until it crosses zero" {
    var source = tex.Source{};
    _ = source.latch(tex.off.lustart, @bitCast(@as(i32, -32)));
    _ = source.latch(tex.off.luxadd, 16);
    try std.testing.expectEqual(@as(i64, -2), source.coordinate(0, 0).u);
    try std.testing.expectEqual(@as(i64, 0), source.coordinate(2, 0).u);
}

test "V carries its fraction into the integer part" {
    var source = tex.Source{};
    _ = source.latch(tex.off.lvstarti, 1);
    _ = source.latch(tex.off.lvyxaddf, 0x8000);
    try std.testing.expectEqual(@as(i64, 1), source.coordinate(0, 0).v);
    try std.testing.expectEqual(@as(i64, 1), source.coordinate(1, 0).v);
    try std.testing.expectEqual(@as(i64, 2), source.coordinate(2, 0).v);
    try std.testing.expectEqual(@as(i64, 3), source.coordinate(4, 0).v);
}

test "the LVYXADDF halves step X and Y apart" {
    var source = tex.Source{};
    _ = source.latch(tex.off.lvyxaddf, 0x8000_0000);
    try std.testing.expectEqual(@as(i64, 0), source.coordinate(9, 0).v);
    try std.testing.expectEqual(@as(i64, 1), source.coordinate(0, 2).v);
    _ = source.latch(tex.off.lvyxaddf, 0x8000);
    try std.testing.expectEqual(@as(i64, 1), source.coordinate(2, 0).v);
    try std.testing.expectEqual(@as(i64, 0), source.coordinate(0, 9).v);
}

test "TEXMASK is clamped to the documented maximum per axis" {
    var source = tex.Source{};
    _ = source.latch(tex.off.texmask, 0xFFFF_FFFF);
    const bound = source.masks();
    try std.testing.expectEqual(tex.limits.umask_max, bound.u);
    try std.testing.expectEqual(tex.limits.vmask_max, bound.v);
}

test "an RLE source, a filtered one and an unknown format are all refused" {
    var source = programmed();
    try std.testing.expectEqual(tex.Refusal.rle, source.refusal(tex.control2.rle_enable).?);
    try std.testing.expectEqual(tex.Refusal.filtered, source.refusal(tex.control2.filter_x).?);
    try std.testing.expectEqual(tex.Refusal.filtered, source.refusal(tex.control2.filter_y).?);
    try std.testing.expectEqual(tex.Refusal.format, source.refusal(readFormat(0x7)).?);
}

test "an indexed format with the CLUT disabled is refused, enabled it is not" {
    var source = programmed();
    try std.testing.expectEqual(tex.Refusal.no_clut, source.refusal(readFormat(0x9)).?);
    try std.testing.expectEqual(@as(?tex.Refusal, null), source.refusal(readFormat(0x9) | tex.control2.clut_enable));
}

test "a texture with no origin or pitch, or a pitch past the clamp, is refused" {
    var bare = tex.Source{};
    try std.testing.expectEqual(tex.Refusal.geometry, bare.refusal(0).?);
    _ = bare.latch(tex.off.texorigin, tex_base);
    try std.testing.expectEqual(tex.Refusal.geometry, bare.refusal(0).?);
    _ = bare.latch(tex.off.texpitch, tex.limits.texpitch_max + 1);
    try std.testing.expectEqual(tex.Refusal.geometry, bare.refusal(0).?);
    _ = bare.latch(tex.off.texpitch, tex.limits.texpitch_max);
    try std.testing.expectEqual(@as(?tex.Refusal, null), bare.refusal(0));
}

test "a plain ARGB8888 texel comes back as it was stored" {
    const memory = try store_memory.open();
    defer store_memory.close(memory);
    try memory.writeWord(tex_base, 0xFF11_2233);
    var source = programmed();
    const word = readFormat(0x2);
    try std.testing.expectEqual(@as(?u32, 0xFF11_2233), source.sample(memory, word, 0, 0));
    try std.testing.expectEqual(@as(u64, 1), source.texels);
}

test "the V coordinate steps a whole texture row, not a texel" {
    const memory = try store_memory.open();
    defer store_memory.close(memory);
    try memory.writeWord(tex_base + 8 * 4, 0xFF44_5566);
    var source = programmed();
    _ = source.latch(tex.off.lvyaddi, 1);
    try std.testing.expectEqual(@as(?u32, 0xFF44_5566), source.sample(memory, readFormat(0x2), 0, 1));
}

test "four I4 texels share a byte, low nibble first" {
    const memory = try store_memory.open();
    defer store_memory.close(memory);
    try memory.writeWord(tex_base, 0x0000_0021);
    var source = programmed();
    _ = source.latch(tex.off.texcladdr, 0);
    _ = source.latch(tex.off.texcldata, 0xFF00_0000);
    _ = source.latch(tex.off.texcldata, 0xFF00_00FF);
    _ = source.latch(tex.off.texcldata, 0xFF00_FF00);
    _ = source.latch(tex.off.luxadd, 16);
    const word = readFormat(0xA) | tex.control2.clut_enable;
    try std.testing.expectEqual(@as(?u32, 0xFF00_00FF), source.sample(memory, word, 0, 0));
    try std.testing.expectEqual(@as(?u32, 0xFF00_FF00), source.sample(memory, word, 1, 0));
}

test "ACLUT44 takes its colour from the palette and its alpha from the texel" {
    const memory = try store_memory.open();
    defer store_memory.close(memory);
    try memory.writeWord(tex_base, 0x0000_0081);
    var source = programmed();
    _ = source.latch(tex.off.texcladdr, 1);
    _ = source.latch(tex.off.texcldata, 0xFF11_2233);
    const word = readFormat(0x5) | tex.control2.clut_enable;
    const got = source.sample(memory, word, 0, 0).?;
    try std.testing.expectEqual(@as(u32, 0x11_2233), got & tex.limits.rgb_mask);
    try std.testing.expectEqual(@as(u32, 0x88), got >> 24);
}

test "a 565 palette is expanded, a plain one is not" {
    const memory = try store_memory.open();
    defer store_memory.close(memory);
    try memory.writeWord(tex_base, 0x0000_0000);
    var source = programmed();
    _ = source.latch(tex.off.texcladdr, 0);
    _ = source.latch(tex.off.texcldata, 0xF800);
    const word = readFormat(0x9) | tex.control2.clut_enable;
    try std.testing.expectEqual(@as(?u32, 0xF800), source.sample(memory, word, 0, 0));
    try std.testing.expectEqual(@as(?u32, 0xFFFF_0000), source.sample(memory, word | tex.control2.clut_565, 0, 0));
}

test "a colour-keyed texel paints nothing, and the key ignores alpha" {
    const memory = try store_memory.open();
    defer store_memory.close(memory);
    try memory.writeWord(tex_base, 0xFF00_FF00);
    var source = programmed();
    _ = source.latch(tex.off.colkey, 0x0000_FF00);
    const word = readFormat(0x2) | tex.control2.colkey_enable;
    try std.testing.expectEqual(@as(?u32, null), source.sample(memory, word, 0, 0));
    try std.testing.expectEqual(@as(u64, 1), source.keyed);
    try std.testing.expectEqual(@as(?u32, 0xFF00_FF00), source.sample(memory, readFormat(0x2), 0, 0));
}

test "a coordinate past the mask wraps, and is counted" {
    const memory = try store_memory.open();
    defer store_memory.close(memory);
    try memory.writeWord(tex_base, 0xFF00_0001);
    var source = programmed();
    _ = source.latch(tex.off.luxadd, 16);
    try std.testing.expectEqual(@as(?u32, 0xFF00_0001), source.sample(memory, readFormat(0x2), 8, 0));
    try std.testing.expectEqual(@as(u64, 1), source.wrapped);
}

test "with the clamp bits set the coordinate stops at the edge instead" {
    const memory = try store_memory.open();
    defer store_memory.close(memory);
    try memory.writeWord(tex_base + 7 * 4, 0xFF99_9999);
    var source = programmed();
    _ = source.latch(tex.off.luxadd, 16);
    const word = readFormat(0x2) | tex.control2.clamp_x;
    try std.testing.expectEqual(@as(?u32, 0xFF99_9999), source.sample(memory, word, 9, 0));
    try std.testing.expectEqual(@as(u64, 1), source.wrapped);
}

test "a negative coordinate wraps to the far edge, or clamps to zero" {
    const memory = try store_memory.open();
    defer store_memory.close(memory);
    try memory.writeWord(tex_base, 0xFF00_0001);
    try memory.writeWord(tex_base + 7 * 4, 0xFF00_0007);
    var source = programmed();
    _ = source.latch(tex.off.lustart, @bitCast(@as(i32, -16)));
    try std.testing.expectEqual(@as(?u32, 0xFF00_0007), source.sample(memory, readFormat(0x2), 0, 0));
    try std.testing.expectEqual(@as(?u32, 0xFF00_0001), source.sample(memory, readFormat(0x2) | tex.control2.clamp_x, 0, 0));
}

test "a texture outside RAM is not read, and is counted apart from a fault" {
    const memory = try store_memory.open();
    defer store_memory.close(memory);
    var source = tex.Source{};
    _ = source.latch(tex.off.texorigin, 0x4000_0000);
    _ = source.latch(tex.off.texpitch, 8);
    try std.testing.expectEqual(@as(?u32, null), source.sample(memory, readFormat(0x2), 0, 0));
    try std.testing.expectEqual(@as(u64, 1), source.off_ram);
    try std.testing.expectEqual(@as(u64, 0), source.faults);
    try std.testing.expectEqual(@as(u64, 0), source.texels);
}

test "a fresh source is quiet and a sampled one is not" {
    const memory = try store_memory.open();
    defer store_memory.close(memory);
    var source = programmed();
    try std.testing.expect(source.quiet());
    _ = source.sample(memory, readFormat(0x2), 0, 0);
    try std.testing.expect(!source.quiet());
}

test "a source answers what it holds for a register, and nothing for another's" {
    var source = tex.Source{};
    _ = source.latch(tex.off.texorigin, tex_base);
    _ = source.latch(tex.off.texpitch, 8);
    _ = source.latch(tex.off.colkey, 0x00FF_00FF);
    try std.testing.expectEqual(@as(?u32, tex_base), source.held(tex.off.texorigin));
    try std.testing.expectEqual(@as(?u32, 8), source.held(tex.off.texpitch));
    try std.testing.expectEqual(@as(?u32, 0x00FF_00FF), source.held(tex.off.colkey));
    try std.testing.expectEqual(@as(?u32, null), source.held(0x064));
}

test "the palette cursor and offset read back, and TEXCLDATA holds nothing" {
    var source = tex.Source{};
    _ = source.latch(tex.off.texcladdr, 0x12);
    _ = source.latch(tex.off.texcloffset, 0x34);
    _ = source.latch(tex.off.texcldata, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(?u32, 0x13), source.held(tex.off.texcladdr));
    try std.testing.expectEqual(@as(?u32, 0x34), source.held(tex.off.texcloffset));
    try std.testing.expectEqual(@as(?u32, 0), source.held(tex.off.texcldata));
}
