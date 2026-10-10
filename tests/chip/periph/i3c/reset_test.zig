//! Covers src/chip/periph/i3c/reset.zig: which RSTCTL bits are commands, which
//! of them take the channel back to idle, and what a store leaves behind.
const std = @import("std");
const ra8 = @import("ra8");

const rstctl = ra8.chip.periph.i3c_reset;

test "the two whole-block resets take the channel back to idle" {
    try std.testing.expect(rstctl.resetsChannel(rstctl.mask.ri3crst));
    try std.testing.expect(rstctl.resetsChannel(rstctl.mask.intlrst));
    // A per-queue bit on its own does not: what each one resets is not in
    // the tree to read, so it is spent and counted and no more.
    try std.testing.expect(!rstctl.resetsChannel(rstctl.mask.tdbrst));
    try std.testing.expect(!rstctl.resetsChannel(rstctl.mask.queues));
    try std.testing.expect(!rstctl.resetsChannel(0));
}

test "every defined bit is a request" {
    try std.testing.expect(rstctl.requested(rstctl.mask.ri3crst));
    try std.testing.expect(rstctl.requested(rstctl.mask.rsqrst));
    try std.testing.expect(rstctl.requested(rstctl.mask.intlrst));
    try std.testing.expect(!rstctl.requested(0));
    // Bit 7 is not one of RSTCTL's, so it asks for nothing.
    try std.testing.expect(!rstctl.requested(0x80));
}

test "the commands are spent and an undefined bit is not swallowed" {
    try std.testing.expectEqual(@as(u32, 0), rstctl.stored(rstctl.mask.ri3crst));
    try std.testing.expectEqual(@as(u32, 0), rstctl.stored(rstctl.mask.any));
    // Bit 7 and bit 17 are not defined here, so they land as before.
    try std.testing.expectEqual(@as(u32, 0x0002_0080), rstctl.stored(0x0003_00FF));
}
