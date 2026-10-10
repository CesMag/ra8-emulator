//! Covers src/chip/core/cpu/choice.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Choice = ra8.chip.core.cpu.choice.Choice;

test "--cpu takes zig and nothing else (RA8EMU-606)" {
    try std.testing.expectEqual(Choice.zig, Choice.parse("zig").?);
    try std.testing.expect(Choice.parse("other") == null);
    try std.testing.expect(Choice.parse("lockstep") == null);
    try std.testing.expect(Choice.parse("Zig") == null);
    try std.testing.expect(Choice.parse("") == null);
}
