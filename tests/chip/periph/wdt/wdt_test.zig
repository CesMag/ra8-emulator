//! WDT0: arming, the refresh window, the two status flags and the underflow.
const std = @import("std");
const ra8 = @import("ra8");

const wdt = ra8.chip.periph.wdt;
const periph = ra8.chip.periph.registry;

/// A watchdog with the shortest timeout and a window that is open from the
/// reload, which is what a firmware that does not care about the window sets.
fn openWindow() wdt.Wdt {
    var unit = wdt.Wdt.init();
    unit.write(wdt.win_base + wdt.off.wdtcr, 2, wdt.controlWord(0, 0, 3, 3));
    return unit;
}

fn refresh(unit: *wdt.Wdt) void {
    unit.write(wdt.win_base + wdt.off.wdtrr, 1, wdt.refresh.first);
    unit.write(wdt.win_base + wdt.off.wdtrr, 1, wdt.refresh.second);
}

fn statusOf(unit: *wdt.Wdt) u16 {
    return @truncate(unit.read(wdt.win_base + wdt.off.wdtsr, 2));
}

test "a watchdog nobody has refreshed counts nothing and reads clean" {
    var unit = openWindow();
    for (0..64) |_| unit.tick();
    try std.testing.expectEqual(@as(u16, 0), statusOf(&unit));
    // Programming WDTCR is not touching the watchdog: nothing counts until a
    // refresh arms it, so the run stays out of the report.
    try std.testing.expect(unit.quiet());
}

test "the first refresh arms the counter at the programmed reload" {
    var unit = openWindow();
    refresh(&unit);
    try std.testing.expect(unit.armed);
    try std.testing.expectEqual(unit.reload(), unit.counter);
    try std.testing.expectEqual(@as(u16, @intCast(unit.reload())), statusOf(&unit));
}

test "a lone 0xFF is not a refresh sequence" {
    var unit = openWindow();
    unit.write(wdt.win_base + wdt.off.wdtrr, 1, wdt.refresh.second);
    try std.testing.expect(!unit.armed);
    try std.testing.expectEqual(@as(u32, 0), unit.refreshes);
}

test "an armed counter runs down a count at a time" {
    var unit = openWindow();
    refresh(&unit);
    const start = unit.counter;
    for (0..3) |_| unit.count();
    try std.testing.expectEqual(start - 3, unit.counter);
}

test "a longer timeout period reloads further, which dev flattens to one constant" {
    var short = wdt.Wdt.init();
    short.write(wdt.win_base + wdt.off.wdtcr, 2, wdt.controlWord(0, 0, 3, 3));
    var long = wdt.Wdt.init();
    long.write(wdt.win_base + wdt.off.wdtcr, 2, wdt.controlWord(3, 0, 3, 3));
    try std.testing.expect(long.reload() > short.reload());
}

test "the divider slows the count and leaves the reload alone" {
    var plain = wdt.Wdt.init();
    plain.write(wdt.win_base + wdt.off.wdtcr, 2, wdt.controlWord(0, 1, 3, 3));
    var divided = wdt.Wdt.init();
    divided.write(wdt.win_base + wdt.off.wdtcr, 2, wdt.controlWord(0, 4, 3, 3));
    try std.testing.expectEqual(plain.reload(), divided.reload());
}

test "a 1024-cycle period reloads CNTVAL to 1023, the count the firmware compares" {
    var unit = openWindow();
    refresh(&unit);
    try std.testing.expectEqual(@as(u16, 1023), statusOf(&unit));
}

test "the counter moves once per ticksPerCount ticks, not once a tick" {
    var unit = wdt.Wdt.init();
    unit.write(wdt.win_base + wdt.off.wdtcr, 2, wdt.controlWord(0, 1, 3, 3));
    refresh(&unit);
    const step = wdt.clock.ticksPerCount(1);
    for (0..step - 1) |_| unit.tick();
    try std.testing.expectEqual(unit.reload(), unit.counter);
    unit.tick();
    try std.testing.expectEqual(unit.reload() - 1, unit.counter);
}

test "a refresh starts the next count afresh" {
    var unit = openWindow();
    refresh(&unit);
    for (0..wdt.clock.ticksPerCount(0) - 1) |_| unit.tick();
    refresh(&unit);
    unit.tick();
    try std.testing.expectEqual(unit.reload(), unit.counter);
}

test "a 50 ms supervisor at TOPS 1024, CKS /4 never runs its watchdog out" {
    // wdt_supervisor_demo: refresh every 50 ms, 1000 ticks of 50000
    // instructions at 1e9 instructions a second.
    var unit = wdt.Wdt.init();
    unit.write(wdt.win_base + wdt.off.wdtcr, 2, wdt.controlWord(0, 1, 3, 3));
    for (0..40) |_| {
        refresh(&unit);
        for (0..1000) |_| unit.tick();
    }
    try std.testing.expectEqual(@as(u32, 0), unit.underflows);
    try std.testing.expectEqual(@as(u32, 40), unit.refreshes);
}

test "a refresh before the window opens is refused and latches REFEF" {
    var unit = wdt.Wdt.init();
    // RPSS 25%: the window opens only once three quarters of the count is gone.
    unit.write(wdt.win_base + wdt.off.wdtcr, 2, wdt.controlWord(0, 0, 0, 3));
    refresh(&unit);
    const loaded = unit.counter;
    unit.count();
    refresh(&unit);
    try std.testing.expectEqual(@as(u32, 1), unit.early);
    try std.testing.expectEqual(loaded - 1, unit.counter);
    try std.testing.expect(statusOf(&unit) & wdt.status.refef != 0);
}

test "the same refresh inside the window reloads and latches nothing" {
    var unit = wdt.Wdt.init();
    unit.write(wdt.win_base + wdt.off.wdtcr, 2, wdt.controlWord(0, 0, 0, 3));
    refresh(&unit);
    while (unit.counter > unit.reload() / 4) unit.count();
    refresh(&unit);
    try std.testing.expectEqual(@as(u32, 0), unit.early);
    try std.testing.expectEqual(@as(u32, 2), unit.refreshes);
    try std.testing.expectEqual(@as(u16, 0), statusOf(&unit) & wdt.status.flags);
}

test "a refresh after the window closes is refused as well" {
    var unit = wdt.Wdt.init();
    // RPES 75%: the window shuts once a quarter of the count has gone.
    unit.write(wdt.win_base + wdt.off.wdtcr, 2, wdt.controlWord(0, 0, 3, 0));
    refresh(&unit);
    while (unit.counter > (unit.reload() * 3) / 4) unit.count();
    unit.count();
    refresh(&unit);
    try std.testing.expectEqual(@as(u32, 1), unit.early);
    try std.testing.expect(statusOf(&unit) & wdt.status.refef != 0);
}

test "running out latches UNDFF once and stops the counter" {
    var unit = openWindow();
    refresh(&unit);
    for (0..unit.reload() + 8) |_| unit.count();
    try std.testing.expectEqual(@as(u32, 1), unit.underflows);
    try std.testing.expect(!unit.armed);
    try std.testing.expect(statusOf(&unit) & wdt.status.undff != 0);
}

test "an underflow in reset mode asks for a reset, in IRQ mode it does not" {
    var irq = openWindow();
    refresh(&irq);
    for (0..irq.reload() + 1) |_| irq.count();
    try std.testing.expect(!irq.reset_requested);

    var reset = openWindow();
    reset.write(wdt.win_base + wdt.off.wdtrcr, 1, wdt.reset_control.rstirqs);
    refresh(&reset);
    for (0..reset.reload() + 1) |_| reset.count();
    try std.testing.expect(reset.reset_requested);
}

test "a refresh error in reset mode asks for a reset too" {
    var unit = wdt.Wdt.init();
    unit.write(wdt.win_base + wdt.off.wdtcr, 2, wdt.controlWord(0, 0, 0, 3));
    unit.write(wdt.win_base + wdt.off.wdtrcr, 1, wdt.reset_control.rstirqs);
    refresh(&unit);
    unit.count();
    refresh(&unit);
    try std.testing.expect(unit.reset_requested);
}

test "a flag is cleared by writing zero at it, and a one clears nothing" {
    var unit = openWindow();
    refresh(&unit);
    for (0..unit.reload() + 1) |_| unit.count();
    try std.testing.expect(statusOf(&unit) & wdt.status.undff != 0);

    // The ack every other flag on this part wants: write the bit as a one.
    unit.write(wdt.win_base + wdt.off.wdtsr, 2, wdt.status.undff);
    try std.testing.expect(statusOf(&unit) & wdt.status.undff != 0);
    try std.testing.expectEqual(@as(u32, 1), unit.bad_acks);

    unit.write(wdt.win_base + wdt.off.wdtsr, 2, 0);
    try std.testing.expectEqual(@as(u16, 0), statusOf(&unit) & wdt.status.flags);
}

test "a write cannot raise a flag that is not latched" {
    var unit = openWindow();
    unit.write(wdt.win_base + wdt.off.wdtsr, 2, wdt.status.flags);
    try std.testing.expectEqual(@as(u16, 0), statusOf(&unit) & wdt.status.flags);
}

test "WDTCR and WDTRCR read back, a byte at a time as well" {
    var unit = wdt.Wdt.init();
    const word = wdt.controlWord(2, 5, 1, 2);
    unit.write(wdt.win_base + wdt.off.wdtcr, 2, word);
    try std.testing.expectEqual(@as(u32, word), unit.read(wdt.win_base + wdt.off.wdtcr, 2));
    try std.testing.expectEqual(@as(u32, word & 0xFF), unit.read(wdt.win_base + wdt.off.wdtcr, 1));
    try std.testing.expectEqual(@as(u32, word >> 8), unit.read(wdt.win_base + wdt.off.wdtcr + 1, 1));

    unit.write(wdt.win_base + wdt.off.wdtrcr, 1, wdt.reset_control.rstirqs);
    try std.testing.expectEqual(@as(u32, wdt.reset_control.rstirqs), unit.read(wdt.win_base + wdt.off.wdtrcr, 1));
}

test "an untouched watchdog stays out of the report" {
    var unit = wdt.Wdt.init();
    try std.testing.expect(unit.quiet());
    for (0..16) |_| unit.tick();
    try std.testing.expect(unit.quiet());
}

test "the block answers on the bus at its documented address" {
    var bus = periph.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var unit = openWindow();
    try bus.add(unit.block());

    bus.write(wdt.win_base + wdt.off.wdtrr, 1, wdt.refresh.first);
    bus.write(wdt.win_base + wdt.off.wdtrr, 1, wdt.refresh.second);
    try std.testing.expect(unit.armed);
    try std.testing.expectEqual(@as(u32, unit.reload()), bus.read(wdt.win_base + wdt.off.wdtsr, 2));
}

test "the Non-secure alias reaches the same watchdog" {
    var bus = periph.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var unit = openWindow();
    try bus.add(unit.block());

    bus.write(periph.ns_offset + wdt.win_base + wdt.off.wdtrr, 1, wdt.refresh.first);
    bus.write(periph.ns_offset + wdt.win_base + wdt.off.wdtrr, 1, wdt.refresh.second);
    try std.testing.expectEqual(@as(u32, 1), unit.refreshes);
}

test "WDTCSTPR reads zero out of reset and keeps the one value it is given" {
    var unit = wdt.Wdt.init();
    try std.testing.expectEqual(@as(u32, 0), unit.read(wdt.win_base + wdt.off.wdtcstpr, 1));
    unit.write(wdt.win_base + wdt.off.wdtcstpr, 1, wdt.count_stop.slcstp);
    try std.testing.expectEqual(@as(u32, wdt.count_stop.slcstp), unit.read(wdt.win_base + wdt.off.wdtcstpr, 1));
    // ra8_wdt_exit_stop writes 0 here expecting the counter to run in Sleep
    // again. HUM Ch 27.3.2 says the register has already had its one write.
    unit.write(wdt.win_base + wdt.off.wdtcstpr, 1, 0);
    try std.testing.expectEqual(@as(u32, wdt.count_stop.slcstp), unit.read(wdt.win_base + wdt.off.wdtcstpr, 1));
    try std.testing.expectEqual(@as(u32, 1), unit.locked_writes);
}

test "WDTCSTPR keeps only SLCSTP, the one bit the register implements" {
    var unit = wdt.Wdt.init();
    unit.write(wdt.win_base + wdt.off.wdtcstpr, 1, 0x7F);
    try std.testing.expectEqual(@as(u32, 0), unit.read(wdt.win_base + wdt.off.wdtcstpr, 1));
}

test "a second WDTCR store lands nowhere and the first settings stand" {
    var unit = openWindow();
    const first = unit.read(wdt.win_base + wdt.off.wdtcr, 2);
    unit.write(wdt.win_base + wdt.off.wdtcr, 2, wdt.controlWord(3, 8, 0, 0));
    try std.testing.expectEqual(first, unit.read(wdt.win_base + wdt.off.wdtcr, 2));
    try std.testing.expectEqual(@as(u32, 1), unit.locked_writes);
}

test "a second WDTRCR store cannot move the part off reset-on-underflow" {
    var unit = openWindow();
    unit.write(wdt.win_base + wdt.off.wdtrcr, 1, wdt.reset_control.rstirqs);
    unit.write(wdt.win_base + wdt.off.wdtrcr, 1, 0);
    try std.testing.expectEqual(@as(u32, wdt.reset_control.rstirqs), unit.read(wdt.win_base + wdt.off.wdtrcr, 1));
    // The underflow still asks for a reset, because RSTIRQS never came off.
    refresh(&unit);
    for (0..unit.reload() + 2) |_| unit.count();
    try std.testing.expect(unit.reset_requested);
}

test "the three control registers are latched one by one, not together" {
    var unit = wdt.Wdt.init();
    unit.write(wdt.win_base + wdt.off.wdtcr, 2, wdt.controlWord(1, 0, 3, 3));
    unit.write(wdt.win_base + wdt.off.wdtrcr, 1, wdt.reset_control.rstirqs);
    unit.write(wdt.win_base + wdt.off.wdtcstpr, 1, wdt.count_stop.slcstp);
    try std.testing.expectEqual(@as(u32, 0), unit.locked_writes);
    try std.testing.expectEqual(@as(u32, wdt.reset_control.rstirqs), unit.read(wdt.win_base + wdt.off.wdtrcr, 1));
    try std.testing.expectEqual(@as(u32, wdt.count_stop.slcstp), unit.read(wdt.win_base + wdt.off.wdtcstpr, 1));
}

test "a byte store spends WDTCR's one write, so the other half never lands" {
    var unit = wdt.Wdt.init();
    unit.write(wdt.win_base + wdt.off.wdtcr, 1, 0x03);
    unit.write(wdt.win_base + wdt.off.wdtcr + 1, 1, 0x30);
    try std.testing.expectEqual(@as(u32, 0x0003), unit.read(wdt.win_base + wdt.off.wdtcr, 2));
    try std.testing.expectEqual(@as(u32, 1), unit.locked_writes);
}

test "the refresh register is not one of the three and takes every sequence" {
    var unit = openWindow();
    refresh(&unit);
    for (0..unit.reload()) |_| unit.count();
    refresh(&unit);
    try std.testing.expectEqual(@as(u32, 2), unit.refreshes);
    try std.testing.expectEqual(@as(u32, 0), unit.locked_writes);
}

test "a dropped control store alone is enough to put WDT0 in the report" {
    var unit = wdt.Wdt.init();
    unit.write(wdt.win_base + wdt.off.wdtrcr, 1, wdt.reset_control.rstirqs);
    try std.testing.expect(unit.quiet());
    unit.write(wdt.win_base + wdt.off.wdtrcr, 1, 0);
    try std.testing.expect(!unit.quiet());
}

test "the window edges are percentages of the full 1024, so 768 and 256 are inside" {
    var unit = wdt.Wdt.init();
    // wdt_window_demo: RPSS 75%, RPES 25%, refreshes while 256 <= CNTVAL <= 768.
    unit.write(wdt.win_base + wdt.off.wdtcr, 2, wdt.controlWord(0, 1, 2, 2));
    refresh(&unit);
    while (unit.counter > 768) unit.count();
    try std.testing.expect(unit.windowOpen());
    while (unit.counter > 256) unit.count();
    try std.testing.expect(unit.windowOpen());
}

test "one count either side of the 75%/25% window is outside it" {
    var unit = wdt.Wdt.init();
    unit.write(wdt.win_base + wdt.off.wdtcr, 2, wdt.controlWord(0, 1, 2, 2));
    refresh(&unit);
    while (unit.counter > 769) unit.count();
    try std.testing.expect(!unit.windowOpen());
    while (unit.counter > 255) unit.count();
    try std.testing.expect(!unit.windowOpen());
}

test "a demo that refreshes at 768 of a 75%/25% window is accepted, not refused" {
    var unit = wdt.Wdt.init();
    unit.write(wdt.win_base + wdt.off.wdtcr, 2, wdt.controlWord(0, 1, 2, 2));
    refresh(&unit);
    while (unit.counter > 768) unit.count();
    refresh(&unit);
    try std.testing.expectEqual(@as(u32, 0), unit.early);
    try std.testing.expectEqual(@as(u32, 2), unit.refreshes);
    try std.testing.expectEqual(unit.reload(), unit.counter);
}
