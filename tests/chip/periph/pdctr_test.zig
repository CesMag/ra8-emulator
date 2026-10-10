//! Covers src/chip/periph/pdctr.zig: the two switchable power domains, each gated
//! off at reset, PDDE's inverted polarity, and the PRC1 lock over the pair.
const std = @import("std");
const ra8 = @import("ra8");

const pdctr = ra8.chip.periph.pdctr;
const prcr = ra8.chip.periph.prcr;

const reg = pdctr.Domain.graphics.base();

/// A protection model with PRC1 already unlocked, which is what a driver does
/// before it touches this register.
fn unlockedGuard() prcr.Prcr {
    var guard = prcr.Prcr.init();
    guard.write(prcr.win_base, 2, prcr.unlockWord(pdctr.guard));
    return guard;
}

test "the domain is gated off at reset and reads its documented value" {
    const guard = prcr.Prcr.init();
    var unit = pdctr.Pdctr.init(&guard, .graphics);
    try std.testing.expectEqual(@as(u32, 0x81), unit.read(reg, 1));
    try std.testing.expect(!unit.powered());
    try std.testing.expect(unit.quiet());
}

test "PDDE is inverted: writing zero powers the domain on" {
    const guard = unlockedGuard();
    var unit = pdctr.Pdctr.init(&guard, .graphics);
    unit.write(reg, 1, 0);
    try std.testing.expect(unit.powered());
    try std.testing.expectEqual(@as(u32, 1), unit.power_ons);
}

test "writing PDDE set leaves the domain gated off" {
    const guard = unlockedGuard();
    var unit = pdctr.Pdctr.init(&guard, .graphics);
    unit.write(reg, 1, pdctr.field.pdde);
    try std.testing.expect(!unit.powered());
    try std.testing.expectEqual(@as(u32, 0), unit.power_ons);
    // It was already off, so nothing was switched off by this write.
    try std.testing.expectEqual(@as(u32, 0), unit.power_offs);
}

test "powering the domain back off after it came up is counted" {
    const guard = unlockedGuard();
    var unit = pdctr.Pdctr.init(&guard, .graphics);
    unit.write(reg, 1, 0);
    unit.write(reg, 1, pdctr.field.pdde);
    try std.testing.expect(!unit.powered());
    try std.testing.expectEqual(@as(u32, 1), unit.power_ons);
    try std.testing.expectEqual(@as(u32, 1), unit.power_offs);
}

test "a write with PRC1 locked is dropped and the domain stays dark" {
    const guard = prcr.Prcr.init();
    var unit = pdctr.Pdctr.init(&guard, .graphics);
    unit.write(reg, 1, 0);
    try std.testing.expect(!unit.powered());
    try std.testing.expectEqual(@as(u32, 1), unit.dropped_locked);
    try std.testing.expectEqual(@as(u32, 0x81), unit.read(reg, 1));
}

test "unlocking a different group does not open this register" {
    var guard = prcr.Prcr.init();
    guard.write(prcr.win_base, 2, prcr.unlockWord(prcr.group.cgc));
    var unit = pdctr.Pdctr.init(&guard, .graphics);
    unit.write(reg, 1, 0);
    try std.testing.expect(!unit.powered());
    try std.testing.expectEqual(@as(u32, 1), unit.dropped_locked);
}

test "a dropped write is silent: no fault, no status flag, old value stands" {
    const guard = prcr.Prcr.init();
    var unit = pdctr.Pdctr.init(&guard, .graphics);
    const before = unit.read(reg, 1);
    unit.write(reg, 1, 0);
    try std.testing.expectEqual(before, unit.read(reg, 1));
}

test "PDCSF settles immediately so a driver polling it makes progress" {
    const guard = unlockedGuard();
    var unit = pdctr.Pdctr.init(&guard, .graphics);
    unit.write(reg, 1, 0);
    try std.testing.expectEqual(@as(u32, 0), unit.read(reg, 1) & pdctr.field.pdcsf);
    unit.write(reg, 1, pdctr.field.pdde);
    try std.testing.expectEqual(@as(u32, 0), unit.read(reg, 1) & pdctr.field.pdcsf);
}

test "PDPGSF follows PDDE, which is the gate state a driver checks" {
    const guard = unlockedGuard();
    var unit = pdctr.Pdctr.init(&guard, .graphics);
    unit.write(reg, 1, 0);
    try std.testing.expectEqual(@as(u32, 0), unit.read(reg, 1) & pdctr.field.pdpgsf);
    unit.write(reg, 1, pdctr.field.pdde);
    try std.testing.expectEqual(@as(u32, pdctr.field.pdpgsf), unit.read(reg, 1) & pdctr.field.pdpgsf);
}

test "the reserved bits of a write are not retained" {
    const guard = unlockedGuard();
    var unit = pdctr.Pdctr.init(&guard, .graphics);
    unit.write(reg, 1, 0x3E);
    try std.testing.expectEqual(@as(u32, 0), unit.read(reg, 1));
}

test "a read is a read whatever width asks for it" {
    const guard = prcr.Prcr.init();
    var unit = pdctr.Pdctr.init(&guard, .graphics);
    try std.testing.expectEqual(@as(u32, 0x81), unit.read(reg, 1));
    try std.testing.expectEqual(@as(u32, 0x81), unit.read(reg, 2));
    try std.testing.expectEqual(@as(u32, 0x81), unit.read(reg, 4));
}

test "the block claims exactly the one byte PDCTRGD occupies" {
    const guard = prcr.Prcr.init();
    var unit = pdctr.Pdctr.init(&guard, .graphics);
    const claimed = unit.block();
    try std.testing.expectEqual(@as(u32, 0x4001_E110), claimed.base);
    try std.testing.expectEqual(@as(u32, 1), claimed.size);
    try std.testing.expect(claimed.covers(0x4001_E110));
    try std.testing.expect(!claimed.covers(0x4001_E111));
}

test "the block answers the bus with the same value the model holds" {
    const guard = unlockedGuard();
    var unit = pdctr.Pdctr.init(&guard, .graphics);
    const claimed = unit.block();
    claimed.writeFn(claimed.context, reg, 1, 0);
    try std.testing.expectEqual(@as(u32, 0), claimed.readFn(claimed.context, reg, 1));
    try std.testing.expect(unit.powered());
}

test "a firmware that never writes the register leaves the domain gated" {
    const guard = unlockedGuard();
    var unit = pdctr.Pdctr.init(&guard, .graphics);
    try std.testing.expect(!unit.powered());
    try std.testing.expect(unit.quiet());
}

test "relocking PRC1 after powering on does not gate the domain again" {
    var guard = unlockedGuard();
    var unit = pdctr.Pdctr.init(&guard, .graphics);
    unit.write(reg, 1, 0);
    guard.write(prcr.win_base, 2, prcr.unlockWord(0));
    try std.testing.expect(unit.powered());
    // The next write is the one that is refused, not the state already set.
    unit.write(reg, 1, pdctr.field.pdde);
    try std.testing.expect(unit.powered());
    try std.testing.expectEqual(@as(u32, 1), unit.dropped_locked);
}
