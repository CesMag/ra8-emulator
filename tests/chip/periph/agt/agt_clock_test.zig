//! Covers src/chip/periph/agt/agt_clock.zig: the AGTMR1 count source, the divider it
//! selects, and the one encoding that counts another channel instead.
const std = @import("std");
const ra8 = @import("ra8");

const clk = ra8.chip.periph.agt_clock;
const agt = ra8.chip.periph.agt;

const ch0 = agt.win_base;
const ch1 = agt.win_base + agt.stride;
const ch2 = agt.win_base + agt.stride * 2;

fn arm(unit: *agt.Agt, base: u32, mr1: u8, period: u16) void {
    unit.write(base + agt.off.mr1, 1, mr1);
    unit.write(base + agt.off.cnt, 2, period);
    unit.write(base + agt.off.cr, 1, agt.control.tstart);
}

test "the four named TCK encodings decode to their sources" {
    try std.testing.expectEqual(clk.Source.pclkb, clk.sourceOf(0x00, 0));
    try std.testing.expectEqual(clk.Source.pclkb_div8, clk.sourceOf(0x10, 0));
    try std.testing.expectEqual(clk.Source.pclkb_div2, clk.sourceOf(0x30, 0));
    try std.testing.expectEqual(clk.Source.agt0_underflow, clk.sourceOf(0x50, 1));
}

test "TMOD in the low bits does not disturb the source" {
    try std.testing.expectEqual(clk.Source.pclkb_div8, clk.sourceOf(0x10 | clk.field.tmod, 0));
}

test "an encoding nobody named counts undivided and says it is unknown" {
    const unnamed = clk.sourceOf(0x70, 0);
    try std.testing.expectEqual(@as(u16, 1), unnamed.divider());
    try std.testing.expectEqualStrings("unknown count source", unnamed.name());
}

test "cascade is channel 1's alone; anywhere else it reads as PCLKB" {
    try std.testing.expectEqual(clk.Source.pclkb, clk.sourceOf(0x50, 0));
    try std.testing.expectEqual(clk.Source.pclkb, clk.sourceOf(0x50, 4));
    try std.testing.expect(clk.sourceOf(0x50, clk.cascade.high).cascaded());
}

test "the dividers are the ones the header names" {
    try std.testing.expectEqual(@as(u16, 1), clk.Source.pclkb.divider());
    try std.testing.expectEqual(@as(u16, 2), clk.Source.pclkb_div2.divider());
    try std.testing.expectEqual(@as(u16, 8), clk.Source.pclkb_div8.divider());
}

test "a step is scaled down by the divider" {
    try std.testing.expectEqual(@as(u16, 0x0800), clk.step(0x0800, .pclkb));
    try std.testing.expectEqual(@as(u16, 0x0400), clk.step(0x0800, .pclkb_div2));
    try std.testing.expectEqual(@as(u16, 0x0100), clk.step(0x0800, .pclkb_div8));
}

test "a divider never scales the step away to nothing" {
    try std.testing.expectEqual(@as(u16, 1), clk.step(4, .pclkb_div8));
}

test "a cascaded channel has no step of its own" {
    try std.testing.expectEqual(@as(u16, 0), clk.step(0x0800, .agt0_underflow));
}

test "every source has a name" {
    try std.testing.expectEqualStrings("PCLKB", clk.Source.pclkb.name());
    try std.testing.expectEqualStrings("PCLKB/8", clk.Source.pclkb_div8.name());
    try std.testing.expectEqualStrings("PCLKB/2", clk.Source.pclkb_div2.name());
    try std.testing.expectEqualStrings("AGT0 underflow", clk.Source.agt0_underflow.name());
}

test "AGTMR1 reads back what was written, where dev answers zero" {
    var unit = agt.Agt.init();
    unit.write(ch2 + agt.off.mr1, 1, 0x13);
    try std.testing.expectEqual(@as(u32, 0x13), unit.read(ch2 + agt.off.mr1, 1));
}

test "a divided channel underflows less often than an undivided one" {
    var unit = agt.Agt.init();
    arm(&unit, ch0, 0x00, agt.step_per_tick * 8 - 1);
    arm(&unit, ch2, 0x10, agt.step_per_tick * 8 - 1);
    for (0..8) |_| unit.tick();
    try std.testing.expectEqual(@as(u32, 1), unit.channels[0].underflows);
    try std.testing.expectEqual(@as(u32, 0), unit.channels[2].underflows);
}

test "the slower channel still moves" {
    var unit = agt.Agt.init();
    arm(&unit, ch2, 0x10, 0xFFFF);
    unit.tick();
    try std.testing.expect(unit.channels[2].counter < 0xFFFF);
}

test "divide by two is exactly half the step" {
    var unit = agt.Agt.init();
    arm(&unit, ch2, 0x30, 0xFFFF);
    unit.tick();
    try std.testing.expectEqual(@as(u16, 0xFFFF - agt.step_per_tick / 2), unit.channels[2].counter);
}

test "a cascaded AGT1 holds still while AGT0 has not underflowed" {
    var unit = agt.Agt.init();
    arm(&unit, ch0, 0x00, 0xFFFF);
    arm(&unit, ch1, 0x50, 4);
    unit.tick();
    try std.testing.expectEqual(@as(u16, 4), unit.channels[1].counter);
    try std.testing.expectEqual(@as(u32, 0), unit.channels[1].cascaded_steps);
}

test "a cascaded AGT1 counts one for each AGT0 underflow" {
    var unit = agt.Agt.init();
    arm(&unit, ch0, 0x00, 0);
    arm(&unit, ch1, 0x50, 4);
    unit.tick();
    try std.testing.expectEqual(@as(u32, 1), unit.channels[0].underflows);
    try std.testing.expectEqual(@as(u16, 3), unit.channels[1].counter);
    try std.testing.expectEqual(@as(u32, 1), unit.channels[1].cascaded_steps);
}

test "a stopped cascade channel takes no underflow, and says so" {
    var unit = agt.Agt.init();
    arm(&unit, ch0, 0x00, 0);
    unit.write(ch1 + agt.off.mr1, 1, 0x50);
    unit.write(ch1 + agt.off.cnt, 2, 4);
    unit.tick();
    try std.testing.expectEqual(@as(u16, 4), unit.channels[1].counter);
    try std.testing.expectEqual(@as(u32, 0), unit.channels[1].cascaded_steps);
    // The count does not move, but the underflow it missed is not silent:
    // the pair was started backwards and the 32-bit value is short by one.
    try std.testing.expectEqual(@as(u32, 1), unit.channels[1].dropped_cascade);
    try std.testing.expect(!unit.channels[1].quiet());
}

test "cascading is what the channel reports as its source" {
    var unit = agt.Agt.init();
    unit.write(ch1 + agt.off.mr1, 1, 0x50);
    try std.testing.expectEqual(clk.Source.agt0_underflow, unit.channels[1].source(1));
    try std.testing.expectEqual(clk.Source.pclkb, unit.channels[0].source(0));
}

test "an underflow is count + 1 counts away, each one divider of PCLKB edges" {
    // 100 MHz PCLKB is 10 ns an edge; a count of 9 underflows on the 10th.
    try std.testing.expectEqual(@as(?u64, 100), clk.underflowInNs(9, .pclkb, 100_000_000));
    try std.testing.expectEqual(@as(?u64, 200), clk.underflowInNs(9, .pclkb_div2, 100_000_000));
    try std.testing.expectEqual(@as(?u64, 800), clk.underflowInNs(9, .pclkb_div8, 100_000_000));
    // At zero the next count is the borrow.
    try std.testing.expectEqual(@as(?u64, 10), clk.underflowInNs(0, .pclkb, 100_000_000));
}

test "an underflow time rounds up, and a channel with no clock has none" {
    // 3 edges at 120 MHz is 25 ns exactly; 1 edge is 8.33 ns, rounded to 9.
    try std.testing.expectEqual(@as(?u64, 25), clk.underflowInNs(2, .pclkb, 120_000_000));
    try std.testing.expectEqual(@as(?u64, 9), clk.underflowInNs(0, .pclkb, 120_000_000));
    try std.testing.expectEqual(@as(?u64, null), clk.underflowInNs(5, .agt0_underflow, 120_000_000));
    try std.testing.expectEqual(@as(?u64, null), clk.underflowInNs(5, .pclkb, 0));
    // The full 16-bit span at PCLKB/8 does not overflow the arithmetic.
    try std.testing.expectEqual(@as(?u64, 65536 * 8 * 10), clk.underflowInNs(0xFFFF, .pclkb_div8, 100_000_000));
}
