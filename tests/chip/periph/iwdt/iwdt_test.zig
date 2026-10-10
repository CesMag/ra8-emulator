//! The IWDT block: the refresh protocol, the counter, and the flags.
const std = @import("std");
const ra8 = @import("ra8");

const iwdt = ra8.chip.periph.iwdt;

fn refreshed(unit: *iwdt.Iwdt) void {
    unit.write(iwdt.win_base + iwdt.off.rr, 1, iwdt.refresh.byte.first);
    unit.write(iwdt.win_base + iwdt.off.rr, 1, iwdt.refresh.byte.second);
}

test "an untouched block is quiet and its counter is not running" {
    var unit = iwdt.Iwdt.init();
    try std.testing.expect(unit.quiet());
    unit.tick();
    try std.testing.expectEqual(iwdt.full_scale, unit.counter);
}

test "the two-byte sequence arms the counter" {
    var unit = iwdt.Iwdt.init();
    refreshed(&unit);
    try std.testing.expect(unit.armed);
    try std.testing.expectEqual(@as(u32, 1), unit.refreshes);
}

test "a single write to IWDTRR refreshes nothing" {
    var unit = iwdt.Iwdt.init();
    unit.write(iwdt.win_base + iwdt.off.rr, 1, iwdt.refresh.byte.second);
    try std.testing.expect(!unit.armed);
    try std.testing.expectEqual(@as(u32, 0), unit.refreshes);
    try std.testing.expectEqual(@as(u32, 1), unit.dropped);
}

test "an armed counter falls at every boundary" {
    var unit = iwdt.Iwdt.init();
    refreshed(&unit);
    unit.tick();
    try std.testing.expectEqual(iwdt.full_scale - iwdt.counts_per_tick, unit.counter);
    try std.testing.expectEqual(@as(u32, iwdt.full_scale - iwdt.counts_per_tick), unit.read(iwdt.win_base + iwdt.off.sr, 2));
}

test "a refresh puts the counter back to full scale" {
    var unit = iwdt.Iwdt.init();
    refreshed(&unit);
    unit.tick();
    unit.tick();
    refreshed(&unit);
    try std.testing.expectEqual(iwdt.full_scale, unit.counter);
}

test "an unfed counter underflows and latches UNDFF" {
    var unit = iwdt.Iwdt.init();
    refreshed(&unit);
    for (0..64) |_| unit.tick();
    try std.testing.expect(unit.underflows > 0);
    try std.testing.expect(unit.read(iwdt.win_base + iwdt.off.sr, 2) & iwdt.status.field.undff != 0);
}

test "an underflow asks for a reset only when RSTIRQS is set" {
    var unit = iwdt.Iwdt.init();
    refreshed(&unit);
    for (0..64) |_| unit.tick();
    try std.testing.expect(!unit.reset_requested);
    try std.testing.expect(unit.nmis > 0);

    var armed = iwdt.Iwdt.init();
    armed.write(iwdt.win_base + iwdt.off.rcr, 1, iwdt.reset_control.rstirqs);
    refreshed(&armed);
    for (0..64) |_| armed.tick();
    try std.testing.expect(armed.reset_requested);
}

test "the counter keeps running past an underflow, since software cannot stop it" {
    var unit = iwdt.Iwdt.init();
    refreshed(&unit);
    for (0..64) |_| unit.tick();
    try std.testing.expect(unit.armed);
    try std.testing.expect(unit.counter > 0);
}

test "the driver's own status clear takes the flag off and never moves the counter" {
    var unit = iwdt.Iwdt.init();
    refreshed(&unit);
    for (0..64) |_| unit.tick();
    const before = unit.counter;
    const read_back = unit.read(iwdt.win_base + iwdt.off.sr, 2);
    unit.write(iwdt.win_base + iwdt.off.sr, 2, read_back & ~@as(u32, iwdt.status.field.flags));
    try std.testing.expectEqual(@as(u16, 0), unit.flags);
    try std.testing.expectEqual(before, unit.counter);
    try std.testing.expectEqual(@as(u32, 1), unit.frozen_writes);
}

test "a write-one ack clears nothing and is counted" {
    var unit = iwdt.Iwdt.init();
    refreshed(&unit);
    for (0..64) |_| unit.tick();
    unit.write(iwdt.win_base + iwdt.off.sr, 2, iwdt.status.field.flags);
    try std.testing.expect(unit.flags & iwdt.status.field.undff != 0);
    try std.testing.expectEqual(@as(u32, 1), unit.bad_acks);
}

test "IWDTCR and IWDTCSTPR hold what they are given" {
    var unit = iwdt.Iwdt.init();
    unit.write(iwdt.win_base + iwdt.off.cr, 2, 0x3312);
    unit.write(iwdt.win_base + iwdt.off.cstpr, 1, iwdt.count_stop.slcstp);
    try std.testing.expectEqual(@as(u32, 0x3312), unit.read(iwdt.win_base + iwdt.off.cr, 2));
    try std.testing.expectEqual(@as(u32, iwdt.count_stop.slcstp), unit.read(iwdt.win_base + iwdt.off.cstpr, 1));
}

test "a byte store replaces one half of IWDTCR and leaves the other" {
    var unit = iwdt.Iwdt.init();
    unit.write(iwdt.win_base + iwdt.off.cr, 2, 0x1234);
    unit.write(iwdt.win_base + iwdt.off.cr + 1, 1, 0xAB);
    try std.testing.expectEqual(@as(u32, 0xAB34), unit.read(iwdt.win_base + iwdt.off.cr, 2));
}

test "the block covers the window the header gives it" {
    var unit = iwdt.Iwdt.init();
    const desc = unit.block();
    try std.testing.expectEqual(@as(u32, 0x4020_2200), desc.base);
    try std.testing.expectEqual(@as(u32, 0x0C), desc.size);
    try std.testing.expectEqualStrings("IWDT", desc.name);
}

test "an erased OFS0 keeps the counter stopped through every refresh" {
    var unit = iwdt.Iwdt.init();
    unit.applyOptionWord(iwdt.ofs0.erased);
    refreshed(&unit);
    refreshed(&unit);
    try std.testing.expect(!unit.armed);
    try std.testing.expectEqual(@as(u32, 0), unit.refreshes);
    try std.testing.expectEqual(@as(u32, 2), unit.stopped_refreshes);
    try std.testing.expect(unit.stoppedByOptions());
    for (0..64) |_| unit.tick();
    try std.testing.expectEqual(@as(u32, 0), unit.underflows);
    try std.testing.expectEqual(iwdt.full_scale, unit.counter);
}

test "an erased OFS0 that nothing refreshes stays quiet" {
    var unit = iwdt.Iwdt.init();
    unit.applyOptionWord(iwdt.ofs0.erased);
    try std.testing.expect(unit.quiet());
}

test "an auto-start OFS0 runs the counter from reset without a refresh" {
    var unit = iwdt.Iwdt.init();
    unit.applyOptionWord(iwdt.ofs0.erased & ~iwdt.ofs0.field.strt);
    try std.testing.expect(unit.armed);
    try std.testing.expect(!unit.stoppedByOptions());
    unit.tick();
    try std.testing.expect(unit.counter < iwdt.full_scale);
    refreshed(&unit);
    try std.testing.expectEqual(@as(u32, 1), unit.refreshes);
    try std.testing.expectEqual(iwdt.full_scale, unit.counter);
}

test "an IWDT underflow lands on the tick its due time names" {
    var unit = iwdt.Iwdt.init();
    try std.testing.expectEqual(@as(?u64, null), unit.underflowDueAt(0));
    refreshed(&unit);
    // 0x3FFF counts at 1024 a tick: the 16th tick finds it at or under 1024.
    const due = unit.underflowDueAt(0).?;
    try std.testing.expectEqual(@as(u64, 16 * 50_000), due);
    var ticks: u64 = 1;
    while (ticks * 50_000 < due) : (ticks += 1) {
        unit.tick();
        try std.testing.expectEqual(@as(u32, 0), unit.underflows);
    }
    unit.tick();
    try std.testing.expectEqual(@as(u32, 1), unit.underflows);
    // A counter already at zero underflows on the next tick.
    unit.counter = 0;
    try std.testing.expectEqual(@as(?u64, 9 + 50_000), unit.underflowDueAt(9));
}

test "the IWDT counts the virtual ns that passed, not the boundaries" {
    var unit = iwdt.Iwdt.init();
    unit.armed = true;
    unit.counter = iwdt.counts_per_tick * 2 + 1;
    for (0..24) |_| unit.tickFor(2_000);
    try std.testing.expectEqual(iwdt.counts_per_tick * 2 + 1, unit.counter);
    unit.tickFor(2_000);
    try std.testing.expectEqual(iwdt.counts_per_tick + 1, unit.counter);
    unit.tickFor(100_000);
    try std.testing.expectEqual(@as(u32, 1), unit.underflows);
}

test "an armed IWDT puts its underflow on the queue, and only once" {
    var queue = ra8.chip.periph.clocks.event_queue.EventQueue{};
    var unit = iwdt.Iwdt.init();
    try unit.arm(&queue, 0);
    try std.testing.expectEqual(@as(?u64, null), queue.next());
    refreshed(&unit);
    try unit.arm(&queue, 1_000);
    try unit.arm(&queue, 1_000);
    try std.testing.expectEqual(@as(usize, 1), queue.count);
    try std.testing.expectEqual(unit.underflowDueAt(1_000), queue.next());
    try std.testing.expectEqual(ra8.chip.periph.wdt.clock.queue_id.iwdt, queue.items[0].id);
}

test "the IWDT's due time takes off the ns already carried toward its next tick" {
    var unit = iwdt.Iwdt.init();
    refreshed(&unit);
    const plain = unit.underflowDueAt(0).?;
    unit.carry_ns = 20_000;
    try std.testing.expectEqual(plain - 20_000, unit.underflowDueAt(0).?);
}
