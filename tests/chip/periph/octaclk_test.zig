const std = @import("std");
const ra8 = @import("ra8");
const ckcr = ra8.chip.periph.ckcr;
const octaclk = ra8.chip.periph.octaclk;
const prcr = ra8.chip.periph.prcr;

/// OCTACKCR's own window, unlocked, with the select sitting at its reset
/// value: MOCO picked and no handshake behind it.
fn openClocks(protection: *prcr.Prcr) ckcr.Ckcr {
    protection.* = prcr.Prcr.init();
    protection.write(prcr.win_base, 2, prcr.key.value | prcr.group.cgc);
    return ckcr.Ckcr.init(protection);
}

/// SREQ up, SRDY read back, SREQ down: the round HUM Ch 11.2.7 Note 3 calls
/// the documented way to confirm OCTACLK is stable.
fn handshake(clocks: *ckcr.Ckcr) void {
    const at = octaclk.select_address;
    clocks.write(at, 1, ckcr.field.sreq);
    _ = clocks.read(at, 1);
    clocks.write(at, 1, 0);
}

test "out of reset the OCTACLK is not stable, whatever source is selected" {
    var protection = prcr.Prcr.init();
    var clocks = openClocks(&protection);
    const unit = octaclk.Octa.init(&clocks);
    try std.testing.expect(!unit.stable());
}

test "one completed handshake makes the clock stable" {
    var protection = prcr.Prcr.init();
    var clocks = openClocks(&protection);
    var unit = octaclk.Octa.init(&clocks);
    handshake(&clocks);
    try std.testing.expect(unit.stable());
    unit.release();
    try std.testing.expect(unit.quiet());
    try std.testing.expect(!unit.wedged);
}

test "a release before the handshake is counted and wedges the engine" {
    var protection = prcr.Prcr.init();
    var clocks = openClocks(&protection);
    var unit = octaclk.Octa.init(&clocks);
    unit.release();
    try std.testing.expectEqual(@as(u32, 1), unit.early_releases);
    try std.testing.expect(unit.wedged);
    try std.testing.expect(!unit.quiet());
}

test "a handshake after an early release does not un-wedge the run" {
    var protection = prcr.Prcr.init();
    var clocks = openClocks(&protection);
    var unit = octaclk.Octa.init(&clocks);
    unit.release();
    handshake(&clocks);
    try std.testing.expect(unit.stable());
    try std.testing.expect(unit.wedged);
    unit.release();
    try std.testing.expectEqual(@as(u32, 1), unit.early_releases);
}

test "the watch reads the selects live rather than copying them" {
    var protection = prcr.Prcr.init();
    var clocks = openClocks(&protection);
    const unit = octaclk.Octa.init(&clocks);
    try std.testing.expect(!unit.stable());
    handshake(&clocks);
    try std.testing.expect(unit.stable());
}
