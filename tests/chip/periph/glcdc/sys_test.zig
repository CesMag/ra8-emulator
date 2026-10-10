//! GLCDC SYSCNT: the panel clock gate and the status word a driver polls.
const std = @import("std");
const ra8 = @import("ra8");
const sys = ra8.chip.periph.glcdc.sys;

/// What `ra8_glcdc_init` writes into PANEL_CLK: CLKSEL = LCDCLK, CLKEN set,
/// divider /2.
const running_clock: u32 = (1 << sys.clock.source_shift) | sys.clock.enable | 0x02;

fn armed() sys.Syscnt {
    var unit = sys.Syscnt{};
    _ = unit.latch(sys.off.panel_clk, running_clock);
    // Step 3 of ra8_glcdc_start: DTCTEN.VPOSDTC.
    _ = unit.latch(sys.off.dtcten, sys.state.vpos);
    return unit;
}

test "a block nobody touched stays out of the report" {
    const unit = sys.Syscnt{};
    try std.testing.expect(unit.quiet());
}

test "the block owns its five registers and nothing either side" {
    try std.testing.expect(sys.Syscnt.owns(sys.off.dtcten));
    try std.testing.expect(sys.Syscnt.owns(sys.off.panel_clk));
    try std.testing.expect(!sys.Syscnt.owns(sys.off.base - 4));
    try std.testing.expect(!sys.Syscnt.owns(sys.off.base + sys.off.span));
}

test "the pixel clock is gated until CLKEN is written" {
    var unit = sys.Syscnt{};
    try std.testing.expect(!unit.clocked());
    _ = unit.latch(sys.off.panel_clk, running_clock);
    try std.testing.expect(unit.clocked());
    try std.testing.expectEqual(sys.Source.lcdclk, unit.source());
    try std.testing.expectEqual(@as(u32, 2), unit.divider());
}

test "a clock programmed without CLKEN still runs nothing" {
    var unit = sys.Syscnt{};
    _ = unit.latch(sys.off.panel_clk, (1 << sys.clock.source_shift) | 0x02);
    try std.testing.expect(!unit.clocked());
    try std.testing.expect(!unit.startFrame());
    try std.testing.expectEqual(@as(u32, 1), unit.unclocked);
    try std.testing.expectEqual(@as(u32, 0), unit.frames);
}

test "a frame with VPOS armed shows up in STMON" {
    var unit = armed();
    try std.testing.expect(unit.startFrame());
    unit.completeFrame();
    try std.testing.expectEqual(sys.state.vpos, unit.read(sys.off.stmon).?);
    try std.testing.expectEqual(@as(u32, 1), unit.frames);
    try std.testing.expectEqual(@as(u32, 1), unit.detections);
    try std.testing.expectEqual(@as(u32, 0), unit.undetected);
}

test "a frame with the detection disarmed reports nothing at all" {
    var unit = sys.Syscnt{};
    _ = unit.latch(sys.off.panel_clk, running_clock);
    try std.testing.expect(unit.startFrame());
    unit.completeFrame();
    try std.testing.expectEqual(@as(u32, 0), unit.read(sys.off.stmon).?);
    try std.testing.expectEqual(@as(u32, 1), unit.undetected);
}

test "a second frame does not count the same latched state twice" {
    var unit = armed();
    unit.completeFrame();
    unit.completeFrame();
    try std.testing.expectEqual(@as(u32, 2), unit.frames);
    try std.testing.expectEqual(@as(u32, 1), unit.detections);
}

test "STCLR takes the status back down, one bit at a time" {
    var unit = armed();
    unit.completeFrame();
    unit.underflow(1);
    _ = unit.latch(sys.off.dtcten, sys.state.all);
    unit.underflow(1);
    try std.testing.expectEqual(sys.state.vpos | sys.state.gr1_underflow, unit.status);
    _ = unit.latch(sys.off.stclr, sys.state.vpos);
    try std.testing.expectEqual(sys.state.gr1_underflow, unit.status);
}

test "clearing a state that was never up is counted, not absorbed" {
    var unit = armed();
    _ = unit.latch(sys.off.stclr, sys.state.vpos | sys.state.gr2_underflow);
    try std.testing.expectEqual(@as(u32, 2), unit.stale_clears);
    try std.testing.expectEqual(@as(u32, 0), unit.status);
}

test "STCLR holds nothing, so it reads back zero" {
    var unit = armed();
    unit.completeFrame();
    _ = unit.latch(sys.off.stclr, sys.state.vpos);
    try std.testing.expectEqual(@as(u32, 0), unit.read(sys.off.stclr).?);
}

test "STMON is read-only: a write to it is counted, not believed" {
    var unit = armed();
    _ = unit.latch(sys.off.stmon, sys.state.all);
    try std.testing.expectEqual(@as(u32, 0), unit.read(sys.off.stmon).?);
    try std.testing.expectEqual(@as(u32, 1), unit.status_writes);
}

test "DTCTEN and INTEN read back what was armed" {
    var unit = sys.Syscnt{};
    _ = unit.latch(sys.off.dtcten, sys.state.all);
    _ = unit.latch(sys.off.inten, sys.state.vpos);
    try std.testing.expectEqual(sys.state.all, unit.read(sys.off.dtcten).?);
    try std.testing.expectEqual(sys.state.vpos, unit.read(sys.off.inten).?);
}

test "reserved bits outside the three states are not armed" {
    var unit = sys.Syscnt{};
    _ = unit.latch(sys.off.dtcten, 0xFFFF_FFFF);
    try std.testing.expectEqual(sys.state.all, unit.read(sys.off.dtcten).?);
}

test "an armed state with INTEN set is what would pend the line" {
    var unit = armed();
    _ = unit.latch(sys.off.inten, sys.state.vpos);
    unit.completeFrame();
    try std.testing.expectEqual(sys.state.vpos, unit.pending());
    try std.testing.expectEqual(@as(u32, 1), unit.interrupts_due);
}

test "a detected state with INTEN clear stands in STMON and pends nothing" {
    var unit = armed();
    unit.completeFrame();
    try std.testing.expectEqual(@as(u32, 0), unit.pending());
    try std.testing.expectEqual(@as(u32, 0), unit.interrupts_due);
}

test "an underflow names the layer that could not keep up" {
    var unit = sys.Syscnt{};
    _ = unit.latch(sys.off.dtcten, sys.state.all);
    unit.underflow(2);
    try std.testing.expectEqual(sys.state.gr2_underflow, unit.status);
    try std.testing.expectEqual(@as(u32, 1), unit.underflows);
}

test "an underflow is counted even with its detection disarmed" {
    var unit = sys.Syscnt{};
    unit.underflow(1);
    try std.testing.expectEqual(@as(u32, 0), unit.status);
    try std.testing.expectEqual(@as(u32, 1), unit.underflows);
}

test "an offset outside the block is nobody's write and nobody's read" {
    var unit = sys.Syscnt{};
    try std.testing.expect(!unit.latch(0x1400, 1));
    try std.testing.expect(unit.read(0x1400) == null);
    try std.testing.expectEqual(@as(u32, 0), unit.writes);
}
