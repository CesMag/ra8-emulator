//! Tests for src/chip/core/cpu/memory/initiator.zig.
const std = @import("std");
const Initiator = @import("ra8").chip.core.cpu.memory.initiator.Initiator;

test "timedIndex gives each timed initiator its own port and none to setup" {
    try std.testing.expectEqual(@as(?usize, null), Initiator.none.timedIndex());
    try std.testing.expectEqual(@as(?usize, 0), Initiator.cpu0.timedIndex());
    try std.testing.expectEqual(@as(?usize, 1), Initiator.cpu1.timedIndex());
    try std.testing.expectEqual(@as(?usize, 2), Initiator.ethos_u55.timedIndex());
}
