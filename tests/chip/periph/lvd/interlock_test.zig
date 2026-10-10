const std = @import("std");
const ra8 = @import("ra8");
const interlock = ra8.chip.periph.lvd.interlock;
const regs = ra8.chip.periph.lvd.regs;

test "the rise-detect band needs the reset path armed first" {
    var locked = interlock.Locked{};
    const cr0: u8 = 0;
    try std.testing.expectEqual(@as(u8, 0), locked.band(.monitor, cr0, regs.hysteresis.rhsel));
    try std.testing.expectEqual(@as(u32, 1), locked.bands);
    try std.testing.expect(!locked.quiet());
}

test "with RI set the band lands" {
    var locked = interlock.Locked{};
    const armed: u8 = regs.control.ri;
    try std.testing.expectEqual(
        @as(u8, regs.hysteresis.rhsel),
        locked.band(.monitor, armed, regs.hysteresis.rhsel),
    );
    try std.testing.expectEqual(@as(u32, 0), locked.bands);
}

test "clearing RHSEL is always legal, armed or not" {
    var locked = interlock.Locked{};
    try std.testing.expectEqual(@as(u8, 0), locked.band(.monitor, 0, 0));
    try std.testing.expectEqual(@as(u32, 0), locked.bands);
}

test "an n channel has no RI bit, so its band is never gated" {
    var locked = interlock.Locked{};
    try std.testing.expectEqual(
        @as(u8, regs.hysteresis.rhsel),
        locked.band(.reset_only, 0, regs.hysteresis.rhsel),
    );
    try std.testing.expectEqual(@as(u32, 0), locked.bands);
}

test "RN cannot be raised while the rise-detect band is selected" {
    var locked = interlock.Locked{};
    const kept = locked.negate(.monitor, regs.hysteresis.rhsel, 0, regs.control.rn | regs.control.rie);
    try std.testing.expectEqual(@as(u8, regs.control.rie), kept);
    try std.testing.expectEqual(@as(u32, 1), locked.negations);
}

test "RN lands in the fall-detect band" {
    var locked = interlock.Locked{};
    try std.testing.expectEqual(
        @as(u8, regs.control.rn),
        locked.negate(.monitor, 0, 0, regs.control.rn),
    );
    try std.testing.expectEqual(@as(u32, 0), locked.negations);
}

test "a read-modify-write carrying an RN that already stands is not a refusal" {
    var locked = interlock.Locked{};
    const standing: u8 = regs.control.rn;
    const kept = locked.negate(.monitor, regs.hysteresis.rhsel, standing, regs.control.rn | regs.control.rie);
    try std.testing.expectEqual(@as(u8, regs.control.rn | regs.control.rie), kept);
    try std.testing.expectEqual(@as(u32, 0), locked.negations);
}

test "an n channel has no RN bit, so CR0 is never gated there" {
    var locked = interlock.Locked{};
    try std.testing.expectEqual(
        @as(u8, regs.control.rn),
        locked.negate(.reset_only, regs.hysteresis.rhsel, 0, regs.control.rn),
    );
    try std.testing.expect(locked.quiet());
}
