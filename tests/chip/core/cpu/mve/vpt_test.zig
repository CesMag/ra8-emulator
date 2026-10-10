//! Covers src/chip/core/cpu/mve/vpt.zig.
const std = @import("std");
const ra8 = @import("ra8");
const vpt = ra8.chip.core.cpu.mve.vpt;
const Vpr = ra8.chip.core.cpu.mve.predicate.Vpr;

fn runs(start: Vpr, count: usize) [4]u16 {
    var out = @as([4]u16, @splat(0));
    var v = start;
    for (0..count) |i| {
        out[i] = vpt.elementMask(v);
        v = vpt.advance(v);
    }
    return out;
}

test "openBeats leaves completed mask pairs untouched" {
    const before: Vpr = .{ .mask01 = 0b0101, .mask23 = 0b1010 };
    const resumed = vpt.openBeats(before, 0b1100, 0xF000);
    try std.testing.expectEqual(@as(u4, 0b0101), resumed.mask01);
    try std.testing.expectEqual(@as(u4, 0b1100), resumed.mask23);
}

test "outside a block nothing is predicated" {
    try std.testing.expectEqual(@as(u16, 0xFFFF), vpt.elementMask(.{ .p0 = 0x1234 }));
    try std.testing.expect(!vpt.inBlock(.{ .p0 = 0x1234 }));
}

test "VPSTTE (mask 1010) runs P0, inverted, then inverted again" {
    const v = vpt.open(.{ .p0 = 0x0F0F }, 0b1010);
    try std.testing.expectEqual([4]u16{ 0x0F0F, 0xF0F0, 0xF0F0, 0 }, runs(v, 3));
}

test "VPSTETE (mask 1111) flips each instruction and then closes" {
    var v = vpt.open(.{ .p0 = 0x00FF }, 0b1111);
    try std.testing.expectEqual([4]u16{ 0x00FF, 0xFF00, 0x00FF, 0xFF00 }, runs(v, 4));
    for (0..4) |_| v = vpt.advance(v);
    try std.testing.expect(!vpt.inBlock(v));
    try std.testing.expectEqual(@as(u16, 0xFFFF), vpt.elementMask(v));
}

test "VPSTTT (mask 0001) keeps P0 for four instructions" {
    var v = vpt.open(.{ .p0 = 0xA5A5 }, 0b0001);
    try std.testing.expectEqual([4]u16{ 0xA5A5, 0xA5A5, 0xA5A5, 0xA5A5 }, runs(v, 4));
    for (0..3) |_| v = vpt.advance(v);
    try std.testing.expect(vpt.inBlock(v));
    try std.testing.expect(!vpt.inBlock(vpt.advance(v)));
}

test "a beat pair out of the block reads as all ones" {
    const v: Vpr = .{ .p0 = 0x0000, .mask01 = 0b1000, .mask23 = 0 };
    try std.testing.expectEqual(@as(u16, 0xFF00), vpt.elementMask(v));
}
