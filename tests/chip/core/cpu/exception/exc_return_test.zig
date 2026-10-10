//! Covers src/chip/core/cpu/exception/exc_return.zig.
const std = @import("std");
const exc_return = @import("ra8").chip.core.cpu.exception.exc_return;

test "entry makes the Secure basic-frame values for each mode and stack" {
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF9), exc_return.forEntry(.{ .thread = true, .psp = false }));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFD), exc_return.forEntry(.{ .thread = true, .psp = true }));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF1), exc_return.forEntry(.{ .thread = false, .psp = false }));
}

test "decode gives back what entry encoded" {
    for ([_]exc_return.Target{
        .{ .thread = true, .psp = false },
        .{ .thread = true, .psp = true },
        .{ .thread = false, .psp = false },
        .{ .thread = true, .psp = false, .fp = true },
        .{ .thread = true, .psp = true, .fp = true },
        .{ .thread = false, .psp = false, .fp = true },
    }) |target| {
        try std.testing.expectEqual(target, exc_return.decode(exc_return.forEntry(target)).?);
    }
}

test "decode turns away the forms the core does not make" {
    try std.testing.expectEqual(@as(?exc_return.Target, null), exc_return.decode(0xFFFF_FFFF)); // reserved bit 1: LR at reset
    try std.testing.expectEqual(@as(?exc_return.Target, null), exc_return.decode(0xFFFF_FFF5)); // Handler on the PSP
    try std.testing.expectEqual(@as(?exc_return.Target, null), exc_return.decode(0xFFFF_FF79)); // bit 7 clear
}

test "decode takes a Non-secure exception over Secure code (S set, ES clear)" {
    const target = exc_return.decode(0xFFFF_FFF8).?;
    try std.testing.expect(!target.secure);
    try std.testing.expect(target.secure_stack);
    try std.testing.expect(target.thread);
}

test "only bits 31:24 all set mark an exception return" {
    try std.testing.expect(exc_return.marks(0xFFFF_FFF9));
    try std.testing.expect(exc_return.marks(0xFF00_0000));
    try std.testing.expect(!exc_return.marks(0xFEFF_FFFF));
    try std.testing.expect(!exc_return.marks(0x2000_0101));
}

test "an FP context clears FType" {
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFE9), exc_return.forEntry(.{ .thread = true, .psp = false, .fp = true }));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFED), exc_return.forEntry(.{ .thread = true, .psp = true, .fp = true }));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFE1), exc_return.forEntry(.{ .thread = false, .psp = false, .fp = true }));
    try std.testing.expect(exc_return.decode(0xFFFF_FFE9).?.fp);
    try std.testing.expect(!exc_return.decode(0xFFFF_FFF9).?.fp);
}

test "a Non-secure exception clears S and ES and decodes back" {
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFB8), exc_return.forEntry(.{ .thread = true, .psp = false, .secure = false, .secure_stack = false }));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFBC), exc_return.forEntry(.{ .thread = true, .psp = true, .secure = false, .secure_stack = false }));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFB0), exc_return.forEntry(.{ .thread = false, .psp = false, .secure = false, .secure_stack = false }));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFAC), exc_return.forEntry(.{ .thread = true, .psp = true, .fp = true, .secure = false, .secure_stack = false }));
    const target = exc_return.decode(0xFFFF_FFBC).?;
    try std.testing.expect(!target.secure and target.thread and target.psp and !target.fp);
}

test "a Secure exception over Non-secure code keeps ES and clears S" {
    const target: exc_return.Target = .{ .thread = true, .psp = false, .secure = true, .secure_stack = false };
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFB9), exc_return.forEntry(target));
    try std.testing.expectEqual(target, exc_return.decode(0xFFFF_FFB9).?);
}
