//! Tests for src/chip/periph/npu/vela_bias.zig. Every byte pattern here was
//! produced by Vela 3.12.0's own `encode_bias`, so a decode that matches
//! them reads the records Vela emits.
const std = @import("std");
const ra8 = @import("ra8");
const bias = ra8.chip.periph.npu_vela.bias;

fn expectRecord(bytes: [10]u8, b: i40, scale: u32, shift: u6) !void {
    const record = bias.decode(&bytes).?;
    try std.testing.expectEqual(b, record.bias);
    try std.testing.expectEqual(scale, record.scale);
    try std.testing.expectEqual(shift, record.shift);
}

test "decode reads what encode_bias wrote" {
    try expectRecord(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 0, 0, 0);
    try expectRecord(.{ 210, 4, 0, 0, 0, 0, 0, 0, 64, 31 }, 1234, 0x4000_0000, 31);
    try expectRecord(.{ 31, 248, 255, 255, 255, 154, 121, 130, 90, 38 }, -2017, 0x5A82_799A, 38);
}

test "decode covers the ends of each field" {
    try expectRecord(.{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 63 }, -1, 0xFFFF_FFFF, 63);
    try expectRecord(.{ 0, 0, 0, 0, 128, 1, 0, 0, 0, 0 }, -(1 << 39), 1, 0);
    try expectRecord(.{ 255, 255, 255, 255, 127, 120, 86, 52, 18, 40 }, (1 << 39) - 1, 0x1234_5678, 40);
}

test "a record with the reserved bits set is refused" {
    const bytes = [10]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x40 };
    try std.testing.expect(bias.decode(&bytes) == null);
}

test "at picks one channel's record and stops at the end" {
    const records = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } ++ [_]u8{ 210, 4, 0, 0, 0, 0, 0, 0, 64, 31 };
    try std.testing.expectEqual(@as(i40, 1234), bias.at(&records, 1).?.bias);
    try std.testing.expect(bias.at(&records, 2) == null);
    try std.testing.expect(bias.at(records[0..15], 1) == null);
}
