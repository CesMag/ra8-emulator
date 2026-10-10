//! Covers src/chip/periph/ulpt.zig: the low-power timer two deep-idle images wake
//! themselves on, and the three places dev lets a misbehaving image pass.
const std = @import("std");
const ra8 = @import("ra8");

const ulpt = ra8.chip.periph.ulpt;

const ch0 = ulpt.win_base;
const ch1 = ulpt.win_base + ulpt.stride;

fn armed(unit: *ulpt.Ulpt, period: u32) void {
    unit.write(ch0 + ulpt.off.cnt, 4, period);
    unit.write(ch0 + ulpt.off.cr, 1, ulpt.control.tstart);
}

test "a reset channel is stopped, empty and silent" {
    var unit = ulpt.Ulpt.init();
    try std.testing.expectEqual(@as(u32, 0), unit.read(ch0 + ulpt.off.cr, 1));
    try std.testing.expectEqual(@as(u32, 0), unit.read(ch0 + ulpt.off.cnt, 4));
    try std.testing.expect(unit.quiet());
}

test "a counter write seeds both the count and the reload" {
    var unit = ulpt.Ulpt.init();
    unit.write(ch0 + ulpt.off.cnt, 4, 0x4000);
    try std.testing.expectEqual(@as(u32, 0x4000), unit.read(ch0 + ulpt.off.cnt, 4));
    try std.testing.expectEqual(@as(u32, 0x4000), unit.channels[0].reload);
}

test "TSTART sets the read-only count-status flag firmware polls" {
    var unit = ulpt.Ulpt.init();
    armed(&unit, 0x4000);
    const cr = unit.read(ch0 + ulpt.off.cr, 1);
    try std.testing.expect(cr & ulpt.control.tstart != 0);
    try std.testing.expect(cr & ulpt.control.tcstf != 0);
}

test "a stopped channel holds its count" {
    var unit = ulpt.Ulpt.init();
    unit.write(ch0 + ulpt.off.cnt, 4, 0x4000);
    unit.tick();
    try std.testing.expectEqual(@as(u32, 0x4000), unit.read(ch0 + ulpt.off.cnt, 4));
    try std.testing.expectEqual(@as(u32, 0), unit.channels[0].underflows);
}

test "an armed channel underflows and reloads its period" {
    var unit = ulpt.Ulpt.init();
    armed(&unit, 0x4000);
    unit.tick();
    try std.testing.expectEqual(@as(u32, 1), unit.channels[0].underflows);
    try std.testing.expect(unit.read(ch0 + ulpt.off.cr, 1) & ulpt.control.tundf != 0);
    try std.testing.expect(unit.read(ch0 + ulpt.off.cnt, 4) <= 0x4000);
}

test "the underflow raises the ULPT0 event once per period" {
    var unit = ulpt.Ulpt.init();
    armed(&unit, 0x4000);
    unit.tick();
    const due = unit.dueEvents();
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expectEqual(ulpt.event.underflow, due.get(0));
    try std.testing.expectEqual(@as(usize, 0), unit.dueEvents().len);
}

test "dev raises once, here every underflow is an interrupt request" {
    var unit = ulpt.Ulpt.init();
    armed(&unit, 0x4000);
    // TUNDF is never cleared, which is where dev stops raising.
    unit.tick();
    _ = unit.dueEvents();
    unit.tick();
    try std.testing.expectEqual(@as(u32, 2), unit.channels[0].underflows);
    try std.testing.expectEqual(@as(usize, 1), unit.dueEvents().len);
}

test "TUNDF is sticky until a write of zero takes it off" {
    var unit = ulpt.Ulpt.init();
    armed(&unit, 0x4000);
    unit.tick();
    unit.write(ch0 + ulpt.off.cr, 1, ulpt.control.tstart | ulpt.control.tundf);
    try std.testing.expect(unit.read(ch0 + ulpt.off.cr, 1) & ulpt.control.tundf != 0);
    unit.write(ch0 + ulpt.off.cr, 1, ulpt.control.tstart);
    try std.testing.expect(unit.read(ch0 + ulpt.off.cr, 1) & ulpt.control.tundf == 0);
}

test "TSTOP beats TSTART in the same write, which dev discards" {
    var unit = ulpt.Ulpt.init();
    armed(&unit, 0x4000);
    unit.write(ch0 + ulpt.off.cr, 1, ulpt.control.tstart | ulpt.control.tstop);
    try std.testing.expectEqual(@as(u32, 0), unit.read(ch0 + ulpt.off.cr, 1));
    try std.testing.expectEqual(@as(u32, 1), unit.channels[0].forced_stops);
    unit.tick();
    try std.testing.expectEqual(@as(u32, 0), unit.channels[0].underflows);
}

test "a forced stop of an idle channel is not counted as one" {
    var unit = ulpt.Ulpt.init();
    unit.write(ch0 + ulpt.off.cr, 1, ulpt.control.tstop);
    try std.testing.expectEqual(@as(u32, 0), unit.channels[0].forced_stops);
}

test "TCSTF cannot be written on, only followed" {
    var unit = ulpt.Ulpt.init();
    unit.write(ch0 + ulpt.off.cr, 1, ulpt.control.tcstf);
    try std.testing.expectEqual(@as(u32, 0), unit.read(ch0 + ulpt.off.cr, 1));
}

test "the ULPTMR2 divider orders the period, which dev ignores" {
    var slow = ulpt.Ulpt.init();
    slow.write(ch0 + ulpt.off.mr2, 1, 3); // divide by 8
    armed(&slow, ulpt.ticks_per_chunk * 2);
    var fast = ulpt.Ulpt.init();
    armed(&fast, ulpt.ticks_per_chunk * 2);
    try std.testing.expect(slow.channels[0].divider() > fast.channels[0].divider());
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        slow.tick();
        fast.tick();
    }
    try std.testing.expect(fast.channels[0].underflows > slow.channels[0].underflows);
}

test "a period longer than one chunk counts down across chunks" {
    var unit = ulpt.Ulpt.init();
    armed(&unit, ulpt.ticks_per_chunk * 4);
    unit.tick();
    try std.testing.expectEqual(@as(u32, 0), unit.channels[0].underflows);
    try std.testing.expect(unit.read(ch0 + ulpt.off.cnt, 4) < ulpt.ticks_per_chunk * 4);
}

test "channel 1 counts but raises no event" {
    var unit = ulpt.Ulpt.init();
    unit.write(ch1 + ulpt.off.cnt, 4, 0x4000);
    unit.write(ch1 + ulpt.off.cr, 1, ulpt.control.tstart);
    unit.tick();
    try std.testing.expectEqual(@as(u32, 1), unit.channels[1].underflows);
    try std.testing.expectEqual(@as(usize, 0), unit.dueEvents().len);
}

test "the channels keep their own counters" {
    var unit = ulpt.Ulpt.init();
    unit.write(ch0 + ulpt.off.cnt, 4, 0x1111);
    unit.write(ch1 + ulpt.off.cnt, 4, 0x2222);
    try std.testing.expectEqual(@as(u32, 0x1111), unit.read(ch0 + ulpt.off.cnt, 4));
    try std.testing.expectEqual(@as(u32, 0x2222), unit.read(ch1 + ulpt.off.cnt, 4));
}

test "a byte read of the counter sees its own lane" {
    var unit = ulpt.Ulpt.init();
    unit.write(ch0 + ulpt.off.cnt, 4, 0xAABBCCDD);
    try std.testing.expectEqual(@as(u32, 0xDD), unit.read(ch0 + ulpt.off.cnt, 1));
    try std.testing.expectEqual(@as(u32, 0xCC), unit.read(ch0 + ulpt.off.cnt + 1, 1));
    try std.testing.expectEqual(@as(u32, 0xBBCC), unit.read(ch0 + ulpt.off.cnt + 1, 2));
}

test "the mode and io bytes read back what was written" {
    var unit = ulpt.Ulpt.init();
    unit.write(ch0 + ulpt.off.mr1, 1, 0x51);
    unit.write(ch0 + ulpt.off.mr3, 1, 0x80);
    unit.write(ch0 + ulpt.off.ioc, 1, 0x04);
    try std.testing.expectEqual(@as(u32, 0x51), unit.read(ch0 + ulpt.off.mr1, 1));
    try std.testing.expectEqual(@as(u32, 0x80), unit.read(ch0 + ulpt.off.mr3, 1));
    try std.testing.expectEqual(@as(u32, 0x04), unit.read(ch0 + ulpt.off.ioc, 1));
}

test "a compare value is stored, given back and counted as a touch" {
    var unit = ulpt.Ulpt.init();
    unit.write(ch0 + ulpt.off.cma, 4, 0x200);
    unit.write(ch0 + ulpt.off.cmb, 4, 0x300);
    try std.testing.expectEqual(@as(u32, 0x200), unit.read(ch0 + ulpt.off.cma, 4));
    try std.testing.expect(unit.channels[0].compares.touches >= 3);
    try std.testing.expect(!unit.quiet());
}

test "a running channel that passes its compare raises TCMAF" {
    var unit = ulpt.Ulpt.init();
    unit.write(ch0 + ulpt.off.cnt, 4, 0x8000);
    unit.write(ch0 + ulpt.off.cma, 4, 0x4000);
    unit.write(ch0 + ulpt.off.cr, 1, ulpt.control.tstart);
    unit.tick();
    try std.testing.expect(unit.read(ch0 + ulpt.off.cr, 1) & ulpt.control.tcmaf != 0);
    try std.testing.expectEqual(@as(u32, 1), unit.channels[0].compares.matches_a);
}

test "a stopped channel never reaches its compare" {
    var unit = ulpt.Ulpt.init();
    unit.write(ch0 + ulpt.off.cnt, 4, 0x8000);
    unit.write(ch0 + ulpt.off.cma, 4, 0x4000);
    unit.tick();
    try std.testing.expectEqual(@as(u32, 0), unit.channels[0].compares.matches_a);
    try std.testing.expect(unit.read(ch0 + ulpt.off.cr, 1) & ulpt.control.tcmaf == 0);
}

test "a compare flag clears by writing its bit zero, like TUNDF" {
    var unit = ulpt.Ulpt.init();
    unit.write(ch0 + ulpt.off.cnt, 4, 0x8000);
    unit.write(ch0 + ulpt.off.cmb, 4, 0x4000);
    unit.write(ch0 + ulpt.off.cr, 1, ulpt.control.tstart);
    unit.tick();
    try std.testing.expect(unit.read(ch0 + ulpt.off.cr, 1) & ulpt.control.tcmbf != 0);
    // Writing the bit back keeps it; writing without it clears it.
    unit.write(ch0 + ulpt.off.cr, 1, ulpt.control.tstart | ulpt.control.tcmbf);
    try std.testing.expect(unit.read(ch0 + ulpt.off.cr, 1) & ulpt.control.tcmbf != 0);
    unit.write(ch0 + ulpt.off.cr, 1, ulpt.control.tstart);
    try std.testing.expect(unit.read(ch0 + ulpt.off.cr, 1) & ulpt.control.tcmbf == 0);
}

test "a channel programmed with a compare it never reaches is not quiet" {
    var unit = ulpt.Ulpt.init();
    unit.write(ch0 + ulpt.off.cma, 4, 0x1234);
    try std.testing.expect(!unit.quiet());
    try std.testing.expectEqual(@as(u32, 0), unit.channels[0].compares.matches_a);
}

test "an address past the last channel answers zero and changes nothing" {
    var unit = ulpt.Ulpt.init();
    unit.write(ulpt.win_base + ulpt.win_span, 4, 0xFFFF);
    try std.testing.expectEqual(@as(u32, 0), unit.read(ulpt.win_base + ulpt.win_span, 4));
    try std.testing.expect(unit.quiet());
}

test "a backlog of underflows drains one event per boundary" {
    var unit = ulpt.Ulpt.init();
    armed(&unit, 0x4000);
    unit.tick();
    unit.tick();
    try std.testing.expectEqual(@as(usize, 1), unit.dueEvents().len);
    try std.testing.expectEqual(@as(usize, 1), unit.dueEvents().len);
    try std.testing.expectEqual(@as(usize, 0), unit.dueEvents().len);
}

test "the block covers both channels and nothing else" {
    var unit = ulpt.Ulpt.init();
    const window = unit.block();
    try std.testing.expect(window.covers(ch1 + ulpt.off.ioc));
    try std.testing.expect(!window.covers(ulpt.win_base + ulpt.win_span));
}

test "a 32-bit period loaded in two halfword stores lands whole" {
    var unit = ulpt.Ulpt.init();
    unit.write(ch0 + ulpt.off.cnt, 2, 0xBEEF);
    unit.write(ch0 + ulpt.off.cnt + 2, 2, 0xDEAD);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), unit.read(ch0 + ulpt.off.cnt, 4));
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), unit.channels[0].reload);
}

test "a narrow read answers the lanes it names, not the whole register" {
    var unit = ulpt.Ulpt.init();
    unit.write(ch0 + ulpt.off.cnt, 4, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 0xBEEF), unit.read(ch0 + ulpt.off.cnt, 2));
    try std.testing.expectEqual(@as(u32, 0xDEAD), unit.read(ch0 + ulpt.off.cnt + 2, 2));
    try std.testing.expectEqual(@as(u32, 0xAD), unit.read(ch0 + ulpt.off.cnt + 2, 1));
}

test "a halfword store at the control register starts the channel and selects its source" {
    var unit = ulpt.Ulpt.init();
    unit.write(ch0 + ulpt.off.cnt, 4, 0x4000);
    const both: u32 = ulpt.control.tstart | (@as(u32, 0x03) << 8);
    unit.write(ch0 + ulpt.off.cr, 2, both);
    try std.testing.expect(unit.channels[0].running());
    try std.testing.expectEqual(@as(u8, 0x03), unit.channels[0].mr1);
}

test "a word read of the control group answers all four of its registers" {
    var unit = ulpt.Ulpt.init();
    unit.write(ch0 + ulpt.off.mr1, 1, 0x11);
    unit.write(ch0 + ulpt.off.mr2, 1, 0x22);
    unit.write(ch0 + ulpt.off.mr3, 1, 0x33);
    unit.write(ch0 + ulpt.off.cr, 1, ulpt.control.tstart);
    const word = unit.read(ch0 + ulpt.off.cr, 4);
    try std.testing.expectEqual(@as(u32, 0x11), (word >> 8) & 0xFF);
    try std.testing.expectEqual(@as(u32, 0x22), (word >> 16) & 0xFF);
    try std.testing.expectEqual(@as(u32, 0x33), (word >> 24) & 0xFF);
    try std.testing.expect(word & ulpt.control.tstart != 0);
}

test "a byte store into a compare value leaves the rest of it standing" {
    var unit = ulpt.Ulpt.init();
    unit.write(ch0 + ulpt.off.cma, 4, 0x1234_5678);
    unit.write(ch0 + ulpt.off.cma + 3, 1, 0xFF);
    try std.testing.expectEqual(@as(u32, 0xFF34_5678), unit.read(ch0 + ulpt.off.cma, 4));
}

test "one access is one compare touch, however many bytes it names" {
    var unit = ulpt.Ulpt.init();
    unit.write(ch0 + ulpt.off.cma, 4, 0x20);
    try std.testing.expectEqual(@as(u32, 1), unit.channels[0].compares.touches);
    _ = unit.read(ch0 + ulpt.off.cma, 4);
    try std.testing.expectEqual(@as(u32, 2), unit.channels[0].compares.touches);
    _ = unit.read(ch0 + ulpt.off.cr, 1);
    try std.testing.expectEqual(@as(u32, 2), unit.channels[0].compares.touches);
}

test "a byte past the I/O control register holds nothing and reads zero" {
    var unit = ulpt.Ulpt.init();
    unit.write(ch0 + ulpt.off.ioc + 1, 1, 0xFF);
    try std.testing.expectEqual(@as(u32, 0), unit.read(ch0 + ulpt.off.ioc + 1, 1));
    try std.testing.expectEqual(@as(u32, 0), unit.read(ch1 - 1, 1));
}
