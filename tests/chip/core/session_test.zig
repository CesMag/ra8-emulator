//! Tests for src/chip/core/session.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Session = ra8.chip.core.session.Session;

test "a bare session runs one uninterrupted stretch" {
    const bare = Session{};
    try std.testing.expect(bare.watch == null);
    try std.testing.expect(bare.timebase == null);
    try std.testing.expect(bare.interrupts == null);
    try std.testing.expect(bare.board == null);
    try std.testing.expect(bare.reboot == null);
    try std.testing.expect(bare.stop == null);
    try std.testing.expect(bare.protection == null);
    try std.testing.expect(bare.undefined_sites == null);
}
