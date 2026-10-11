//! Covers src/chip/core/cpu/exception/fp_frame.zig.
const std = @import("std");
const ra8 = @import("ra8");
const frame = ra8.chip.core.cpu.exception.frame;
const fp_frame = ra8.chip.core.cpu.exception.fp.frame;
const fixture = @import("../ram.zig");

const basic: frame.Frame = .{ 1, 2, 3, 4, 12, 0x14, 0x2000_0102, 0x0100_0200 };

fn sampleFp() fp_frame.Fp {
    var fp: fp_frame.Fp = .{ .s = undefined, .fpscr = 0x0300_0000 };
    for (&fp.s, 0..) |*s, i| s.* = 0x3F80_0000 + @as(u32, @intCast(i));
    return fp;
}

test "an aligned stack takes the 0x68-byte frame right below it" {
    var ram: fixture.Ram = .{};
    const at = try fp_frame.push(ram.view(), fixture.msp_top, basic, sampleFp());
    try std.testing.expectEqual(fixture.msp_top - 0x68, at);
    try std.testing.expectEqual(@as(u32, 1), ram.word(at));
    try std.testing.expectEqual(@as(u32, 0x2000_0102), ram.word(at + 0x18));
    try std.testing.expectEqual(@as(u32, 0x0100_0000), ram.word(at + 0x1C));
    try std.testing.expectEqual(@as(u32, 0x3F80_0000), ram.word(at + 0x20));
    try std.testing.expectEqual(@as(u32, 0x3F80_000F), ram.word(at + 0x5C));
    try std.testing.expectEqual(@as(u32, 0x0300_0000), ram.word(at + 0x60));
    try std.testing.expectEqual(@as(u32, 0), ram.word(at + 0x64));
}

test "VPR rides in the word after FPSCR and pops back" {
    var ram: fixture.Ram = .{};
    var fp = sampleFp();
    fp.vpr = 0x0084_1234; // P0 0x1234, MASK01 0x4, MASK23 0x8
    const at = try fp_frame.push(ram.view(), fixture.msp_top, basic, fp);
    try std.testing.expectEqual(@as(u32, 0x0084_1234), ram.word(at + 0x64));
    const popped = try fp_frame.pop(ram.view(), at, false);
    try std.testing.expectEqual(@as(u32, 0x0084_1234), popped.fp.vpr);
}

test "a 4-byte aligned stack is padded down and bit 9 records it" {
    var ram: fixture.Ram = .{};
    const at = try fp_frame.push(ram.view(), fixture.msp_top - 4, basic, sampleFp());
    try std.testing.expectEqual(fixture.msp_top - 0x70, at);
    try std.testing.expectEqual(@as(u32, 0x0100_0200), ram.word(at + 0x1C));
}

test "pop reads both halves back and undoes the padding" {
    var ram: fixture.Ram = .{};
    for ([_]u32{ fixture.msp_top, fixture.msp_top - 4 }) |sp| {
        const at = try fp_frame.push(ram.view(), sp, basic, sampleFp());
        const popped = try fp_frame.pop(ram.view(), at, false);
        try std.testing.expectEqual(sp, popped.sp);
        try std.testing.expectEqual(basic[frame.slot.return_address], popped.frame[frame.slot.return_address]);
        try std.testing.expectEqualSlices(u32, &sampleFp().s, &popped.fp.s);
        try std.testing.expectEqual(@as(u32, 0x0300_0000), popped.fp.fpscr);
    }
}

test "a frame that would leave memory fails" {
    var ram: fixture.Ram = .{};
    try std.testing.expectError(error.Unmapped, fp_frame.push(ram.view(), fixture.base + 0x40, basic, sampleFp()));
}

test "with S16-S31 the frame is 0xA8 bytes and they follow the VPR word" {
    var ram: fixture.Ram = .{};
    var fp = sampleFp();
    var high: [16]u32 = undefined;
    for (&high, 0..) |*s, i| s.* = 0x4000_0000 + @as(u32, @intCast(i));
    fp.high = high;
    const at = try fp_frame.push(ram.view(), fixture.msp_top, basic, fp);
    try std.testing.expectEqual(fixture.msp_top - 0xA8, at);
    try std.testing.expectEqual(@as(u32, 0x0300_0000), ram.word(at + 0x60));
    try std.testing.expectEqual(@as(u32, 0x4000_0000), ram.word(at + 0x68));
    try std.testing.expectEqual(@as(u32, 0x4000_000F), ram.word(at + 0xA4));
    const popped = try fp_frame.pop(ram.view(), at, true);
    try std.testing.expectEqual(fixture.msp_top, popped.sp);
    try std.testing.expectEqualSlices(u32, &high, &popped.fp.high.?);
    try std.testing.expectEqualSlices(u32, &fp.s, &popped.fp.s);
}

test "a reserved frame with S16-S31 is 0xA8 bytes" {
    var ram: fixture.Ram = .{};
    const at = try fp_frame.reserve(ram.view(), fixture.msp_top, basic, true);
    try std.testing.expectEqual(fixture.msp_top - 0xA8, at);
}
