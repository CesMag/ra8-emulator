//! Tests for src/session/stack_low.zig.
const std = @import("std");
const ra8 = @import("ra8");
const stack_low = ra8.session.stack_low;
const region_map = ra8.session.region_map;
const StackMarks = ra8.session.step_hook.zig_core.StackMarks;

/// An 8 KiB reservation like fault_crashlog_hil.elf's.
const reserved: region_map.Stack = .{ .base = 0x220F_DF00, .size = 0x2000, .region = null };

fn report(low_msp: u32, stack: ?region_map.Stack) stack_low.Report {
    const marks: StackMarks = .{ .msp = 0x220F_FF00, .psp = 0, .low_msp = low_msp, .low_psp = 0xFFFF_FFFF };
    return .{ .marks = marks, .stack = stack };
}

test "a main stack that stays inside its reservation has not overflowed" {
    try std.testing.expectEqual(@as(u32, 0), report(0x220F_DF00, reserved).overflowBytes());
    try std.testing.expectEqual(@as(u32, 0), report(0x220F_E800, reserved).overflowBytes());
}

test "a low mark under the base overflowed by the difference" {
    try std.testing.expectEqual(@as(u32, 0x40), report(0x220F_DEC0, reserved).overflowBytes());
    try std.testing.expectEqual(@as(u32, 4), report(0x220F_DEFC, reserved).overflowBytes());
}

test "an unset MSP or an image with no reservation reports no overflow" {
    const never = report(0xFFFF_FFFF, reserved);
    try std.testing.expect(!never.touched());
    try std.testing.expectEqual(@as(u32, 0), never.overflowBytes());
    try std.testing.expectEqual(@as(u32, 0), report(0x1000, null).overflowBytes());
}
