//! Covers src/chip/core/cpu/mve/beats.zig and vpt.advanceBeats, against the
//! beat-wise rules in the Arm ARM (DDI0553).
const std = @import("std");
const ra8 = @import("ra8");
const beats = ra8.chip.core.cpu.mve.beats;
const vpt = ra8.chip.core.cpu.mve.vpt;
const Vpr = ra8.chip.core.cpu.mve.predicate.Vpr;

test "ECI cuts the VPT mask down to the beats still to run" {
    const vpr: Vpr = .{ .p0 = 0x0F0F, .mask01 = 0b1000, .mask23 = 0b1000 };
    try std.testing.expectEqual(@as(u16, 0x0F0F), beats.mask(vpr, 0x00));
    try std.testing.expectEqual(@as(u16, 0x0F00), beats.mask(vpr, 0x20));
    try std.testing.expectEqual(@as(u16, 0xFFF0), beats.mask(.{}, 0x10));
    try std.testing.expectEqual(@as(u16, 0xFFFF), beats.mask(.{}, 0x28));
}

test "retiring moves B0 done on to A0 and clears the rest" {
    try std.testing.expectEqual(@as(u8, 0x10), beats.retire(.{}, 0x50).it);
    try std.testing.expectEqual(@as(u8, 0x00), beats.retire(.{}, 0x40).it);
    try std.testing.expectEqual(@as(u8, 0x28), beats.retire(.{}, 0x28).it);
}

test "a resumed instruction only inverts and shifts for the beats it ran" {
    const vpr: Vpr = .{ .p0 = 0x0000, .mask01 = 0b1100, .mask23 = 0b1100 };
    const full = vpt.advanceBeats(vpr, 0xFFFF);
    try std.testing.expectEqual(vpt.advance(vpr), full);
    try std.testing.expectEqual(@as(u16, 0xFFFF), full.p0);
    const late = vpt.advanceBeats(vpr, 0xF000);
    try std.testing.expectEqual(@as(u16, 0xF000), late.p0);
    try std.testing.expectEqual(@as(u4, 0b1100), late.mask01);
    try std.testing.expectEqual(@as(u4, 0b1000), late.mask23);
    const half = vpt.advanceBeats(vpr, 0xFFF0);
    try std.testing.expectEqual(@as(u4, 0b1000), half.mask01);
    try std.testing.expectEqual(@as(u4, 0b1100), vpt.advanceBeats(vpr, 0xFF00).mask01);
}
