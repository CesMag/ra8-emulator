//! Covers src/chip/core/cpu/cortex.zig.
const std = @import("std");
const ra8 = @import("ra8");

const Cortex = ra8.chip.core.cpu.cortex.Cortex;

test "the register enum names every register the debugger and report read" {
    try std.testing.expectEqual(@as(usize, 59), @typeInfo(Cortex).@"enum".field_names.len);
    try std.testing.expect(@hasField(Cortex, "fpscr"));
    try std.testing.expect(@hasField(Cortex, "msplim"));
    try std.testing.expect(@hasField(Cortex, "psplim"));
    try std.testing.expect(@hasField(Cortex, "s0"));
    try std.testing.expect(@hasField(Cortex, "s31"));
    try std.testing.expect(@hasField(Cortex, "psp"));
    try std.testing.expect(@hasField(Cortex, "vpr"));
}
