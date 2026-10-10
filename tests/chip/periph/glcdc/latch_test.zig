//! Covers src/chip/periph/glcdc/latch.zig: which GLCDC registers carry a VEN,
//! and what a store that sets one leaves behind.
const std = @import("std");
const ra8 = @import("ra8");

const latch = ra8.chip.periph.glcdc.latch;

test "the three registers that carry a VEN, and no others" {
    try std.testing.expectEqual(@as(u32, 0x100), latch.bitAt(latch.latch.bg_en));
    try std.testing.expectEqual(@as(u32, 0x1), latch.bitAt(latch.latch.gr1_en));
    try std.testing.expectEqual(@as(u32, 0x1), latch.bitAt(latch.latch.gr2_en));
    // A layer's own registers do not, nor does the output stage's, which
    // commits on its own OUT_VLATCH inside out.zig.
    try std.testing.expectEqual(@as(u32, 0), latch.bitAt(0x1140));
    try std.testing.expectEqual(@as(u32, 0), latch.bitAt(0x140C));
}

test "a store asks for an update only when it carries that register's bit" {
    try std.testing.expect(latch.requested(latch.latch.bg_en, 0x101));
    try std.testing.expect(!latch.requested(latch.latch.bg_en, 0x1));
    try std.testing.expect(latch.requested(latch.latch.gr1_en, 0x1));
    try std.testing.expect(!latch.requested(latch.latch.gr1_en, 0x100));
    // Bit 8 in a GR_EN is not a VEN, and bit 0 in BG_EN is BG_EN.EN.
    try std.testing.expect(!latch.requested(0x1140, 0x101));
}

test "the command is spent and every other bit is kept" {
    // BG_EN.EN survives its own store: the driver sets EN and VEN together.
    try std.testing.expectEqual(@as(u32, 0x1), latch.stored(latch.latch.bg_en, 0x101));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FEFF), latch.stored(latch.latch.bg_en, 0xFFFF_FFFF));
    try std.testing.expectEqual(@as(u32, 0), latch.stored(latch.latch.gr2_en, 0x1));
    // A register with no VEN keeps the whole value.
    try std.testing.expectEqual(@as(u32, 0x101), latch.stored(0x1140, 0x101));
}
