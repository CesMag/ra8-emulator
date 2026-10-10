//! Covers src/chip/periph/oscsf.zig: the oscillation stabilisation flags, the four
//! stop bits they follow, and the PRC0 gate in front of every store.
const std = @import("std");
const ra8 = @import("ra8");

const oscsf = ra8.chip.periph.oscsf;
const prcr = ra8.chip.periph.prcr;

const base = oscsf.win_base;

/// A protection model with PRC0 already open, the state a driver reaches
/// through RA8_PROTECTED_WRITE before it touches any of these.
fn unlocked() prcr.Prcr {
    var guard = prcr.Prcr.init();
    guard.write(prcr.win_base, 2, prcr.key.value | prcr.group.cgc);
    return guard;
}

test "HOCO comes up running and the other three come up stopped" {
    var guard = unlocked();
    var osc = oscsf.Oscillators.init(&guard);
    const flags = osc.flags();
    try std.testing.expect(flags & oscsf.flag.hocosf != 0);
    try std.testing.expect(flags & oscsf.flag.moscsf == 0);
    try std.testing.expect(flags & oscsf.flag.pll1sf == 0);
    try std.testing.expect(flags & oscsf.flag.pll2sf == 0);
}

test "clearing MOSTP raises MOSCSF and setting it drops the flag again" {
    var guard = unlocked();
    var osc = oscsf.Oscillators.init(&guard);
    osc.write(base + oscsf.regs.mosccr, 1, 0x00);
    try std.testing.expect(osc.running(oscsf.flag.moscsf));
    osc.write(base + oscsf.regs.mosccr, 1, 0x01);
    try std.testing.expect(!osc.running(oscsf.flag.moscsf));
}

test "stopping PLL1 drops PLL1SF, which is what the driver waits on" {
    var guard = unlocked();
    var osc = oscsf.Oscillators.init(&guard);
    osc.write(base + oscsf.regs.pllcr, 1, 0x00);
    try std.testing.expect(osc.running(oscsf.flag.pll1sf));
    // internal_stop_pll1 writes PLLCR = stop outright, then waits for clear.
    osc.write(base + oscsf.regs.pllcr, 1, 0x01);
    try std.testing.expectEqual(@as(u32, 0), osc.read(base + oscsf.regs.oscsf, 1) & oscsf.flag.pll1sf);
}

test "PLL2SF reads clear until PLL2 is actually started" {
    var guard = unlocked();
    var osc = oscsf.Oscillators.init(&guard);
    // ra8_cgc_usb.c line 271 tests this once to decide whether to start PLL2.
    try std.testing.expect(!osc.running(oscsf.flag.pll2sf));
    osc.write(base + oscsf.regs.pll2cr, 1, 0x00);
    try std.testing.expect(osc.running(oscsf.flag.pll2sf));
}

test "OSCSF reads the same value twice, unlike the alternating fallback" {
    var guard = unlocked();
    var osc = oscsf.Oscillators.init(&guard);
    osc.write(base + oscsf.regs.mosccr, 1, 0x00);
    const first = osc.read(base + oscsf.regs.oscsf, 1);
    const second = osc.read(base + oscsf.regs.oscsf, 1);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(u32, oscsf.flag.hocosf | oscsf.flag.moscsf), first);
}

test "OSCSF is read-only and a store to it is counted, not kept" {
    var guard = unlocked();
    var osc = oscsf.Oscillators.init(&guard);
    const before = osc.read(base + oscsf.regs.oscsf, 1);
    osc.write(base + oscsf.regs.oscsf, 1, 0xFF);
    try std.testing.expectEqual(before, osc.read(base + oscsf.regs.oscsf, 1));
    try std.testing.expectEqual(@as(u32, 1), osc.readonly_writes);
}

test "a read-modify-write of HOCOCR keeps the bits above HCSTP" {
    var guard = unlocked();
    var osc = oscsf.Oscillators.init(&guard);
    osc.write(base + oscsf.regs.hococr, 1, 0xF1);
    try std.testing.expect(!osc.running(oscsf.flag.hocosf));
    // ra8_cgc_use_hoco clears HCSTP out of whatever it read back.
    const held = osc.read(base + oscsf.regs.hococr, 1);
    osc.write(base + oscsf.regs.hococr, 1, held & ~@as(u32, oscsf.stop));
    try std.testing.expect(osc.running(oscsf.flag.hocosf));
    try std.testing.expectEqual(@as(u32, 0xF0), osc.read(base + oscsf.regs.hococr, 1));
}

test "starts and stops count only a stop bit that moved" {
    var guard = unlocked();
    var osc = oscsf.Oscillators.init(&guard);
    osc.write(base + oscsf.regs.mosccr, 1, 0x00);
    osc.write(base + oscsf.regs.mosccr, 1, 0x00);
    try std.testing.expectEqual(@as(u32, 1), osc.starts);
    try std.testing.expectEqual(@as(u32, 0), osc.stops);
    osc.write(base + oscsf.regs.mosccr, 1, 0x01);
    try std.testing.expectEqual(@as(u32, 1), osc.stops);
}

test "an untouched unit stays out of the report" {
    var guard = unlocked();
    var osc = oscsf.Oscillators.init(&guard);
    try std.testing.expect(osc.quiet());
    _ = osc.read(base + oscsf.regs.oscsf, 1);
    try std.testing.expect(osc.quiet());
    osc.write(base + oscsf.regs.pllcr, 1, 0x00);
    try std.testing.expect(!osc.quiet());
}

test "the neighbours in the window are retained as written" {
    var guard = unlocked();
    var osc = oscsf.Oscillators.init(&guard);
    // The multiplier and divider registers are stored, not interpreted.
    osc.write(base + 0x06, 1, 0x5A);
    try std.testing.expectEqual(@as(u32, 0x5A), osc.read(base + 0x06, 1));
    try std.testing.expectEqual(@as(u32, 0), osc.readonly_writes);
}

test "a word load spanning OSCSF still reports the computed flags" {
    var guard = unlocked();
    var osc = oscsf.Oscillators.init(&guard);
    osc.write(base + oscsf.regs.mosccr, 1, 0x00);
    const word = osc.read(base + oscsf.regs.oscsf, 4);
    try std.testing.expectEqual(
        @as(u32, oscsf.flag.hocosf | oscsf.flag.moscsf),
        word & 0xFF,
    );
}

test "a store with PRC0 locked is discarded, so the oscillator never starts" {
    var guard = prcr.Prcr.init();
    var osc = oscsf.Oscillators.init(&guard);
    osc.write(base + oscsf.regs.mosccr, 1, 0x00);
    try std.testing.expect(!osc.running(oscsf.flag.moscsf));
    try std.testing.expectEqual(@as(u32, 1), osc.dropped_locked);
    try std.testing.expectEqual(@as(u32, 0), osc.starts);
    try std.testing.expect(!osc.quiet());
}

test "PRC0 locked drops the HOCOCR store ra8_cgc_use_hoco leaves unwrapped" {
    var guard = prcr.Prcr.init();
    var osc = oscsf.Oscillators.init(&guard);
    // ra8_cgc.c:765 clears HCSTP outside any RA8_PROTECTED_WRITE window.
    osc.write(base + oscsf.regs.hococr, 1, 0x01);
    try std.testing.expect(osc.running(oscsf.flag.hocosf));
    try std.testing.expectEqual(@as(u32, 1), osc.dropped_locked);
}

test "reads are never gated, so a locked run can still poll OSCSF" {
    var guard = prcr.Prcr.init();
    var osc = oscsf.Oscillators.init(&guard);
    try std.testing.expectEqual(
        @as(u32, oscsf.flag.hocosf),
        osc.read(base + oscsf.regs.oscsf, 1),
    );
    try std.testing.expectEqual(@as(u32, 0), osc.dropped_locked);
}

test "opening PRC0 lets the same store through that was just dropped" {
    var guard = prcr.Prcr.init();
    var osc = oscsf.Oscillators.init(&guard);
    osc.write(base + oscsf.regs.pll2cr, 1, 0x00);
    try std.testing.expect(!osc.running(oscsf.flag.pll2sf));
    guard.write(prcr.win_base, 2, prcr.key.value | prcr.group.cgc);
    osc.write(base + oscsf.regs.pll2cr, 1, 0x00);
    try std.testing.expect(osc.running(oscsf.flag.pll2sf));
    try std.testing.expectEqual(@as(u32, 1), osc.dropped_locked);
}
