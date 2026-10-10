const std = @import("std");
const ra8 = @import("ra8");
const frame = ra8.chip.periph.spi.frame;

test "a cleared SPCMD0 is an eight-bit MSB-first frame" {
    const f = frame.of(0);
    try std.testing.expectEqual(@as(u6, 8), f.bits());
    try std.testing.expect(!f.lsb_first);
    try std.testing.expect(f.named);
}

test "the three named SPB encodings select their widths" {
    try std.testing.expectEqual(frame.Width.eight, frame.widthOf(frame.spb.eight << frame.field.spb_shift).?);
    try std.testing.expectEqual(frame.Width.sixteen, frame.widthOf(frame.spb.sixteen << frame.field.spb_shift).?);
    try std.testing.expectEqual(frame.Width.thirty_two, frame.widthOf(frame.spb.thirty_two << frame.field.spb_shift).?);
}

test "an encoding the tree does not name is unnamed, not invented" {
    const f = frame.of(0x0A << frame.field.spb_shift);
    try std.testing.expect(!f.named);
    try std.testing.expectEqual(@as(u6, 8), f.bits());
}

test "a cleared data length selected nothing, so nothing is complained about" {
    try std.testing.expect(frame.cleared(0));
    try std.testing.expect(frame.cleared(frame.field.lsbf));
    try std.testing.expect(!frame.cleared(frame.spb.eight << frame.field.spb_shift));
    try std.testing.expect(frame.of(frame.field.lsbf).named);
}

test "the width masks the part of the word the frame carries" {
    try std.testing.expectEqual(@as(u32, 0xFF), frame.Width.eight.mask());
    try std.testing.expectEqual(@as(u32, 0xFFFF), frame.Width.sixteen.mask());
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), frame.Width.thirty_two.mask());
}

test "a width is a whole number of bytes" {
    try std.testing.expectEqual(@as(u6, 1), frame.Width.eight.bytes());
    try std.testing.expectEqual(@as(u6, 2), frame.Width.sixteen.bytes());
    try std.testing.expectEqual(@as(u6, 4), frame.Width.thirty_two.bytes());
}

test "LSBF is read out of bit 12" {
    try std.testing.expect(frame.of(frame.field.lsbf).lsb_first);
    try std.testing.expect(!frame.of(0).lsb_first);
}

test "a sixteen-bit frame keeps both halves" {
    const f = frame.of(frame.spb.sixteen << frame.field.spb_shift);
    try std.testing.expectEqual(@as(u32, 0xABCD), f.onWire(0xABCD));
}

test "an eight-bit frame drops what sits above it" {
    const f = frame.of(0);
    try std.testing.expectEqual(@as(u32, 0xCD), f.onWire(0xABCD));
}

test "a thirty-two-bit frame carries the whole word" {
    const f = frame.of(frame.spb.thirty_two << frame.field.spb_shift);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), f.onWire(0xDEAD_BEEF));
}

test "LSB-first turns the frame end for end" {
    const f = frame.of(frame.field.lsbf);
    try std.testing.expectEqual(@as(u32, 0x80), f.onWire(0x01));
    try std.testing.expectEqual(@as(u32, 0x01), f.onWire(0x80));
}

test "a reversed frame reversed again is the frame" {
    const f = frame.of(frame.field.lsbf | (frame.spb.sixteen << frame.field.spb_shift));
    try std.testing.expectEqual(@as(u32, 0x1234), f.fromWire(f.onWire(0x1234)));
}

test "reversal stays inside the named width" {
    try std.testing.expectEqual(@as(u32, 0x8000), frame.reverse(0x0001, 16));
    try std.testing.expectEqual(@as(u32, 0x0001), frame.reverse(0x8000, 16));
    try std.testing.expectEqual(@as(u32, 0x8000_0000), frame.reverse(0x0000_0001, 32));
}

test "a palindrome survives reversal" {
    try std.testing.expectEqual(@as(u32, 0x81), frame.reverse(0x81, 8));
}

test "LSB-first on a sixteen-bit frame reverses all sixteen bits" {
    const f = frame.of(frame.field.lsbf | (frame.spb.sixteen << frame.field.spb_shift));
    try std.testing.expectEqual(@as(u32, 0x0080), f.onWire(0x0100));
}

test "the command registers sit where the header puts them" {
    try std.testing.expectEqual(@as(u32, 0x14), frame.off.spcmd0);
    try std.testing.expectEqual(@as(usize, 8), frame.off.registers);
}

test "SPB is read out of bits 20 down to 16 and nothing else" {
    const noise: u32 = 0xFFE0_FFFF;
    try std.testing.expect(frame.cleared(noise));
    try std.testing.expect(frame.widthOf(noise) == null);
    try std.testing.expectEqual(frame.Width.sixteen, frame.widthOf(noise | (frame.spb.sixteen << frame.field.spb_shift)).?);
}

test "carriedBy wants an access at least as wide as the frame" {
    const eight = frame.of(frame.spb.eight << frame.field.spb_shift);
    try std.testing.expect(eight.carriedBy(0, 1));
    try std.testing.expect(eight.carriedBy(0, 4));
    const sixteen = frame.of(frame.spb.sixteen << frame.field.spb_shift);
    try std.testing.expect(!sixteen.carriedBy(0, 1));
    try std.testing.expect(sixteen.carriedBy(0, 2));
    const wide = frame.of(frame.spb.thirty_two << frame.field.spb_shift);
    try std.testing.expect(!wide.carriedBy(0, 2));
    try std.testing.expect(wide.carriedBy(0, 4));
}

test "carriedBy wants the bottom lane of the register" {
    const eight = frame.of(frame.spb.eight << frame.field.spb_shift);
    try std.testing.expect(!eight.carriedBy(1, 1));
    try std.testing.expect(!eight.carriedBy(2, 2));
    try std.testing.expect(eight.carriedBy(0, 1));
}

test "an unprogrammed SPCMD0 is carried by any width at the bottom lane" {
    const reset = frame.of(0);
    try std.testing.expect(reset.carriedBy(0, 1));
    try std.testing.expect(reset.carriedBy(0, 4));
}
