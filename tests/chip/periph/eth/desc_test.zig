//! The eight bytes: what they decode to, and what a field write keeps.
const std = @import("std");
const ra8 = @import("ra8");
const desc = ra8.chip.periph.eth.desc;

test "a descriptor decodes size, type and pointer" {
    const raw = [_]u8{ 0x40, 0x02, 0x80, 0x00, 0x00, 0x20, 0x00, 0x22 };
    const entry = desc.Desc.decode(raw);
    try std.testing.expectEqual(@as(u32, 0x240), entry.ds);
    try std.testing.expectEqual(desc.Dt.fsingle, entry.dt);
    try std.testing.expectEqual(@as(u32, 0x2200_2000), entry.ptr);
}

test "the size is twelve bits across two bytes" {
    const raw = [_]u8{ 0xFF, 0x0F, 0x00, 0x00, 0, 0, 0, 0 };
    try std.testing.expectEqual(@as(u32, 0xFFF), desc.Desc.decode(raw).ds);
}

test "byte one's high nibble is not part of the size" {
    const raw = [_]u8{ 0x10, 0xF1, 0x00, 0x00, 0, 0, 0, 0 };
    try std.testing.expectEqual(@as(u32, 0x110), desc.Desc.decode(raw).ds);
}

test "a code with no type is still readable" {
    const raw = [_]u8{ 0, 0, 0x50, 0, 0, 0, 0, 0 };
    try std.testing.expectEqual(@as(u4, 5), @backingInt(desc.Desc.decode(raw).dt));
}

test "the pointer is little-endian" {
    const raw = [_]u8{ 0, 0, 0, 0, 0x78, 0x56, 0x34, 0x12 };
    try std.testing.expectEqual(@as(u32, 0x1234_5678), desc.Desc.decode(raw).ptr);
}

test "a type write keeps the bits below it" {
    try std.testing.expectEqual(@as(u8, 0x4A), desc.dtByte(0x8A, .fempty));
}

test "a size write keeps byte one's high nibble" {
    const bytes = desc.dsBytes(0xF0, 0x123);
    try std.testing.expectEqual(@as(u8, 0x23), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0xF1), bytes[1]);
}

test "a size write and a decode round trip" {
    const bytes = desc.dsBytes(0x00, 0x2A0);
    const raw = [_]u8{ bytes[0], bytes[1], 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqual(@as(u32, 0x2A0), desc.Desc.decode(raw).ds);
}

test "link and linkfix chain, a frame does not" {
    try std.testing.expect(desc.chains(.link));
    try std.testing.expect(desc.chains(.linkfix));
    try std.testing.expect(!desc.chains(.fsingle));
    try std.testing.expect(!desc.chains(.fempty));
}

test "only fempty is a reception slot" {
    try std.testing.expect(desc.free(.fempty));
    try std.testing.expect(!desc.free(.fempty_is));
    try std.testing.expect(!desc.free(.eempty));
}
