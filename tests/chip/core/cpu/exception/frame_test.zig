//! Covers src/chip/core/cpu/exception/frame.zig.
const std = @import("std");
const ra8 = @import("ra8");
const frame = ra8.chip.core.cpu.exception.frame;
const fixture = @import("ram.zig");

const sample: frame.Frame = .{ 1, 2, 3, 4, 12, 0x14, 0x2000_0102, 0x0100_0200 };

test "an 8-byte aligned stack takes the frame right below it" {
    var ram: fixture.Ram = .{};
    const at = try frame.push(ram.view(), fixture.msp_top, sample);
    try std.testing.expectEqual(fixture.msp_top - 0x20, at);
    try std.testing.expectEqual(@as(u32, 1), ram.word(at));
    try std.testing.expectEqual(@as(u32, 12), ram.word(at + 16));
    try std.testing.expectEqual(@as(u32, 0x2000_0102), ram.word(at + 24));
    // Bit 9 of the caller's xPSR is not state; aligned, it is stacked clear.
    try std.testing.expectEqual(@as(u32, 0x0100_0000), ram.word(at + 28));
}

test "a 4-byte aligned stack is padded down and bit 9 records it" {
    var ram: fixture.Ram = .{};
    const at = try frame.push(ram.view(), fixture.msp_top - 4, sample);
    try std.testing.expectEqual(fixture.msp_top - 0x28, at);
    try std.testing.expectEqual(@as(u32, 0x0100_0200), ram.word(at + 28));
}

test "pop reads the frame back and undoes the padding" {
    var ram: fixture.Ram = .{};
    for ([_]u32{ fixture.msp_top, fixture.msp_top - 4 }) |sp| {
        const popped = try frame.pop(ram.view(), try frame.push(ram.view(), sp, sample));
        try std.testing.expectEqual(sp, popped.sp);
        try std.testing.expectEqual(sample[frame.slot.return_address], popped.frame[frame.slot.return_address]);
        try std.testing.expectEqual(@as(u32, 0x14), popped.frame[frame.slot.lr]);
    }
}

test "a frame that would leave memory fails without moving anything" {
    var ram: fixture.Ram = .{};
    try std.testing.expectError(error.Unmapped, frame.push(ram.view(), fixture.base + 0x10, sample));
}
