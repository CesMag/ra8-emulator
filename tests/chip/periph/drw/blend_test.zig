//! Covers src/chip/periph/drw/blend.zig: the blend factors, the alpha mux and the
//! narrowing to the framebuffer format. The vectors are the ones measured on
//! an EK-RA8D2 and recorded in board_periph_drw.c on dev, so a change here
//! that "looks right" but moves a byte fails against silicon, not taste.
const std = @import("std");
const ra8 = @import("ra8");

const blend = ra8.chip.periph.drw.blend;

/// The reset CONTROL2: no invert bits, so both factors are 1, and
/// WRITEALPHA = 00, so the stored alpha comes from COLOR2.
const reset_style = blend.Style.decode(0);

/// A fill that replaces rather than adds: BDI alone.
fn replacing() blend.Style {
    return blend.Style.decode(blend.control2.dst_invert);
}

test "the reset factors are both one, so a fill adds to the framebuffer" {
    try std.testing.expect(!reset_style.src.is_alpha);
    try std.testing.expect(!reset_style.src.invert);
    try std.testing.expectEqual(@as(u32, 255), reset_style.src.numerator(0x80));
    try std.testing.expectEqual(@as(u32, 255), reset_style.dst.numerator(0x80));
}

test "bench: 0xFF00FF00 over 0x00000010 adds to 0xFF00FF10 without BDI" {
    const out = reset_style.shade(0xFF00FF00, 0xFF00_0000, 0x0000_0010);
    try std.testing.expectEqual(@as(u32, 0xFF00FF10), out);
}

test "bench: the same fill with BDI replaces, giving 0xFF00FF00" {
    const out = replacing().shade(0xFF00FF00, 0xFF00_0000, 0x0000_0010);
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), out);
}

test "issue #170: an opaque fill stores COLOR2's alpha, which is zero" {
    const out = reset_style.shade(0xFF00FF00, 0, 0);
    try std.testing.expectEqual(@as(u32, 0), blend.part(out, blend.channel.alpha_shift));
}

test "WRITEALPHA 00 takes COLOR2's alpha and none of its colour" {
    const out = reset_style.shade(0xFF00FF00, 0x8012_3456, 0);
    try std.testing.expectEqual(@as(u32, 0x8000FF00), out);
}

test "WRITEALPHA 01 stores the source alpha" {
    const style = blend.Style.decode(@as(u32, 1) << blend.control2.write_alpha_shift);
    try std.testing.expectEqual(@as(u32, 0x80), style.alpha(0x80, 0x11, 0));
}

test "WRITEALPHA 10 forces zero and 11 keeps the framebuffer's alpha" {
    const zero = blend.Style.decode(@as(u32, 2) << blend.control2.write_alpha_shift);
    const keep = blend.Style.decode(@as(u32, 3) << blend.control2.write_alpha_shift);
    try std.testing.expectEqual(@as(u32, 0), zero.alpha(0x80, 0x11, 0xFF00_0000));
    try std.testing.expectEqual(@as(u32, 0x11), keep.alpha(0x80, 0x11, 0xFF00_0000));
}

test "bench: source-over composites 0x80E04040 onto 0xFF202060 as 0xBF803050" {
    // BSF (source alpha) with BDF+BDI (1 - source alpha), and USEACB so the
    // alpha channel blends by the same shape.
    const word = blend.control2.src_factor | blend.control2.dst_factor |
        blend.control2.dst_invert | blend.control2.use_acb |
        blend.control2.alpha_src_factor | blend.control2.alpha_dst_factor |
        blend.control2.alpha_dst_invert;
    const out = blend.Style.decode(word).shade(0x80E04040, 0, 0xFF202060);
    try std.testing.expectEqual(@as(u32, 0xBF803050), out);
}

test "a factor is one, alpha, zero or one minus alpha" {
    const plain = blend.Factor{ .is_alpha = false, .invert = false };
    const inverted = blend.Factor{ .is_alpha = false, .invert = true };
    const alpha = blend.Factor{ .is_alpha = true, .invert = false };
    const complement = blend.Factor{ .is_alpha = true, .invert = true };
    try std.testing.expectEqual(@as(u32, 255), plain.numerator(0x40));
    try std.testing.expectEqual(@as(u32, 0), inverted.numerator(0x40));
    try std.testing.expectEqual(@as(u32, 0x40), alpha.numerator(0x40));
    try std.testing.expectEqual(@as(u32, 255 - 0x40), complement.numerator(0x40));
}

test "the mix rounds to nearest and saturates at one byte" {
    try std.testing.expectEqual(@as(u32, 0xFF), blend.mix(0xFF, 0xFF, 255, 255));
    try std.testing.expectEqual(@as(u32, 0x80), blend.mix(0xFF, 0, 128, 0));
}

test "WRITEFORMAT decodes across the split field, bit 8 plus bits 21:20" {
    const rgb565 = blend.Style.decode(@as(u32, 1) << blend.control2.format_low_shift);
    const high = blend.Style.decode(blend.control2.format_high);
    try std.testing.expectEqual(blend.Format.rgb565, rgb565.format);
    try std.testing.expectEqual(blend.Format.reserved4, high.format);
    try std.testing.expectEqual(@as(u32, 4), high.format.bytesPerPixel());
}

test "bytes per pixel follows the format" {
    try std.testing.expectEqual(@as(u32, 1), blend.Format.a8.bytesPerPixel());
    try std.testing.expectEqual(@as(u32, 2), blend.Format.rgb565.bytesPerPixel());
    try std.testing.expectEqual(@as(u32, 2), blend.Format.argb4444.bytesPerPixel());
    try std.testing.expectEqual(@as(u32, 4), blend.Format.argb8888.bytesPerPixel());
}

test "packing narrows to RGB565, ARGB4444 and A8" {
    const rgb565 = blend.Style.decode(@as(u32, 1) << blend.control2.format_low_shift);
    const argb4444 = blend.Style.decode(@as(u32, 3) << blend.control2.format_low_shift);
    const a8 = reset_style;
    try std.testing.expectEqual(@as(u32, 0xF800), rgb565.pack(0xFFFF_0000));
    try std.testing.expectEqual(@as(u32, 0xFF00), argb4444.pack(0xFFFF_0000));
    try std.testing.expectEqual(@as(u32, 0xFF), a8.pack(0xFF12_3456));
}

test "ARGB8888 passes through the pack unchanged" {
    const style = blend.Style.decode(@as(u32, 2) << blend.control2.format_low_shift);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), style.pack(0x1234_5678));
}

test "a pattern or texture source is flagged, and nothing else is" {
    try std.testing.expect(!reset_style.patterned);
    try std.testing.expect(!reset_style.textured);
    try std.testing.expect(blend.Style.decode(blend.control2.pattern_enable).patterned);
    try std.testing.expect(blend.Style.decode(blend.control2.texture_enable).textured);
}

test "USEACB blends the alpha channel instead of using the mux" {
    const word = blend.control2.use_acb | blend.control2.alpha_src_factor;
    const style = blend.Style.decode(word);
    // fSA = source alpha, fDA = 1: 0x80 * 0x80/255 + 0x10, rounded.
    try std.testing.expectEqual(@as(u32, 0x50), style.alpha(0x80, 0x10, 0));
}
