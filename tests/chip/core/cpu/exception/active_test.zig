//! Covers src/chip/core/cpu/exception/active.zig.
const std = @import("std");
const active = @import("ra8").chip.core.cpu.exception.active;

test "the stack pushes and pops innermost last, up to its guard" {
    var stack: active.Active = .{};
    try std.testing.expectEqual(@as(?active.Entry, null), stack.running());
    try std.testing.expect(stack.push(.{ .number = 14, .priority = 0xF0 }));
    try std.testing.expect(stack.push(.{ .number = 15, .priority = 0x80 }));
    try std.testing.expectEqual(@as(u9, 15), stack.running().?.number);
    try std.testing.expectEqual(@as(u9, 15), stack.pop().?.number);
    try std.testing.expectEqual(@as(u9, 14), stack.pop().?.number);
    try std.testing.expectEqual(@as(?active.Entry, null), stack.pop());
    for (0..active.Active.max) |_| try std.testing.expect(stack.push(.{ .number = 16, .priority = 0 }));
    try std.testing.expect(stack.full());
    try std.testing.expect(!stack.push(.{ .number = 17, .priority = 0 }));
}

test "execution priority follows the running handler and the masks" {
    var stack: active.Active = .{};
    try std.testing.expectEqual(active.lowest, active.executionPriority(&stack, 0, 0, 0, 0));
    _ = stack.push(.{ .number = 15, .priority = 0x80 });
    try std.testing.expectEqual(@as(i16, 0x80), active.executionPriority(&stack, 0, 0, 0, 0));
    try std.testing.expectEqual(@as(i16, 0x40), active.executionPriority(&stack, 0, 0x40, 0, 0));
    try std.testing.expectEqual(@as(i16, 0x80), active.executionPriority(&stack, 0, 0xC0, 0, 0)); // BASEPRI below it changes nothing
    try std.testing.expectEqual(@as(i16, 0), active.executionPriority(&stack, 1, 0x40, 0, 0));
    try std.testing.expectEqual(@as(i16, -1), active.executionPriority(&stack, 1, 0x40, 1, 0));
}

test "PRIGROUP drops the subpriority bits from the handler and BASEPRI" {
    var stack: active.Active = .{};
    try std.testing.expect(stack.push(.{ .number = 16, .priority = 0x60 }));
    // PRIGROUP 5: bits [5:0] are subpriority, so 0x60 is group 0x40.
    try std.testing.expectEqual(@as(i16, 0x40), active.executionPriority(&stack, 0, 0, 0, 5));
    try std.testing.expectEqual(@as(i16, 0x40), active.executionPriority(&stack, 0, 0x7F, 0, 5));
    try std.testing.expectEqual(@as(i16, 0x60), active.executionPriority(&stack, 0, 0, 0, 0));
}

test "group keeps only the bits above PRIGROUP" {
    try std.testing.expectEqual(@as(u8, 0xA4), active.group(0xA5, 0));
    try std.testing.expectEqual(@as(u8, 0x80), active.group(0xA5, 5));
    try std.testing.expectEqual(@as(u8, 0x00), active.group(0xFF, 7));
}
