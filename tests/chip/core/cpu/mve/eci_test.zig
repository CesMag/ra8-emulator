//! Covers src/chip/core/cpu/mve/eci.zig. Values follow the ECI encodings and
//! beat rules in the Arm ARM (DDI0553).
const std = @import("std");
const ra8 = @import("ra8");
const eci = ra8.chip.core.cpu.mve.eci;

test "a zero low nibble reads the high nibble as ECI" {
    try std.testing.expectEqual(eci.State{ .eci = .none }, eci.fromIt(0x00));
    try std.testing.expectEqual(eci.State{ .eci = .a0 }, eci.fromIt(0x10));
    try std.testing.expectEqual(eci.State{ .eci = .a0a1 }, eci.fromIt(0x20));
    try std.testing.expectEqual(eci.State{ .eci = .a0a1a2 }, eci.fromIt(0x40));
    try std.testing.expectEqual(eci.State{ .eci = .a0a1a2b0 }, eci.fromIt(0x50));
}

test "an open IT block is IT state, other ECI values are reserved" {
    try std.testing.expectEqual(eci.State.it, eci.fromIt(0x08));
    try std.testing.expectEqual(eci.State.it, eci.fromIt(0x1C));
    for ([_]u8{ 0x30, 0x60, 0x70, 0x80, 0xF0 }) |it| try std.testing.expectEqual(eci.State.reserved, eci.fromIt(it));
}

test "completed beats clear their byte lanes" {
    try std.testing.expectEqual(@as(u16, 0xFFFF), eci.beatMask(eci.fromIt(0x00)));
    try std.testing.expectEqual(@as(u16, 0xFFF0), eci.beatMask(eci.fromIt(0x10)));
    try std.testing.expectEqual(@as(u16, 0xFF00), eci.beatMask(eci.fromIt(0x20)));
    try std.testing.expectEqual(@as(u16, 0xF000), eci.beatMask(eci.fromIt(0x40)));
    try std.testing.expectEqual(@as(u16, 0xF000), eci.beatMask(eci.fromIt(0x50)));
    try std.testing.expectEqual(@as(u16, 0xFFFF), eci.beatMask(eci.fromIt(0x08)));
}

test "only a resumed instruction skips its first beat" {
    try std.testing.expect(!eci.skipsFirstBeat(eci.fromIt(0x00)));
    try std.testing.expect(!eci.skipsFirstBeat(eci.fromIt(0x08)));
    for ([_]u8{ 0x10, 0x20, 0x40, 0x50 }) |it| try std.testing.expect(eci.skipsFirstBeat(eci.fromIt(it)));
}

test "B0 done becomes A0 of the next instruction, the rest clears" {
    try std.testing.expectEqual(@as(u8, 0x10), eci.next(0x50));
    for ([_]u8{ 0x00, 0x10, 0x20, 0x40 }) |it| try std.testing.expectEqual(@as(u8, 0), eci.next(it));
    try std.testing.expectEqual(@as(u8, 0x1C), eci.next(0x1C));
}
