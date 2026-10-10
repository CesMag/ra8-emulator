//! Covers src/chip/core/cpu/exception/callee.zig.
const std = @import("std");
const ra8 = @import("ra8");
const callee = ra8.chip.core.cpu.exception.callee;
const fixture = @import("ram.zig");

const sample: callee.Callee = .{ 4, 5, 6, 7, 8, 9, 10, 11 };

test "the signature's bit 0 is FType" {
    try std.testing.expectEqual(@as(u32, 0xFEFA_125B), callee.signature(false));
    try std.testing.expectEqual(@as(u32, 0xFEFA_125A), callee.signature(true));
}

test "push lays out the signature, a reserved word and R4-R11 below the caller frame" {
    var ram: fixture.Ram = .{};
    const at = try callee.push(ram.view(), fixture.msp_top, sample, false);
    try std.testing.expectEqual(fixture.msp_top - 0x28, at);
    try std.testing.expectEqual(@as(u32, 0xFEFA_125B), ram.word(at));
    try std.testing.expectEqual(@as(u32, 0), ram.word(at + 4));
    try std.testing.expectEqual(@as(u32, 4), ram.word(at + 8));
    try std.testing.expectEqual(@as(u32, 11), ram.word(at + 36));
}

test "pop gives the registers back and the caller frame's address" {
    var ram: fixture.Ram = .{};
    for ([_]bool{ false, true }) |fp| {
        const popped = try callee.pop(ram.view(), try callee.push(ram.view(), fixture.msp_top, sample, fp), fp);
        try std.testing.expectEqual(fixture.msp_top, popped.sp);
        try std.testing.expectEqualSlices(u32, &sample, &popped.callee);
    }
}

test "a corrupted signature is an integrity failure" {
    var ram: fixture.Ram = .{};
    const at = try callee.push(ram.view(), fixture.msp_top, sample, false);
    ram.putWord(at, 0xDEAD_BEEF);
    try std.testing.expectError(error.Integrity, callee.pop(ram.view(), at, false));
}

test "a signature for the other FType is an integrity failure" {
    var ram: fixture.Ram = .{};
    const at = try callee.push(ram.view(), fixture.msp_top, sample, true);
    try std.testing.expectError(error.Integrity, callee.pop(ram.view(), at, false));
}

test "a context that would leave memory fails" {
    var ram: fixture.Ram = .{};
    try std.testing.expectError(error.Unmapped, callee.push(ram.view(), fixture.base + 0x10, sample, false));
}
