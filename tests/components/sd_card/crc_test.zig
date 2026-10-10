//! Covers src/components/sd_card/crc.zig.
const std = @import("std");
const sd_crc = @import("ra8").components.sd_crc;

test "an empty block checksums to zero" {
    try std.testing.expectEqual(@as(u16, 0), sd_crc.crc16(&.{}));
}

test "the check string gives the CCITT value the driver computes" {
    try std.testing.expectEqual(@as(u16, 0x31C3), sd_crc.crc16("123456789"));
}

test "a single zero byte still runs the polynomial" {
    try std.testing.expectEqual(@as(u16, 0), sd_crc.crc16(&.{0}));
    try std.testing.expectEqual(@as(u16, 0x1021), sd_crc.crc16(&.{ 0, 1 }));
}

test "one changed byte changes the checksum" {
    var block: [512]u8 = @splat(0);
    const clean = sd_crc.crc16(&block);
    block[100] = 0xA5;
    try std.testing.expect(clean != sd_crc.crc16(&block));
}
