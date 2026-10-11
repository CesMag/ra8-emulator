//! The MIPI DSI host window.
const std = @import("std");
const ra8 = @import("ra8");

const dsi = ra8.chip.periph.mipi.dsi;
const rule = ra8.chip.periph.mipi.dsi.link;

const base = dsi.win_base;

fn at(part: *dsi.MipiDsi, offset: u32) u32 {
    return part.read(base + offset, 4);
}

fn put(part: *dsi.MipiDsi, offset: u32, value: u32) void {
    part.write(base + offset, 4, value);
}

test "a fresh host is quiet and reports an idle link" {
    var part = dsi.MipiDsi.init();
    try std.testing.expect(part.quiet());
    try std.testing.expectEqual(@as(u32, 0), part.linksr());
    try std.testing.expectEqual(@as(u32, 0), part.sends());
}

test "LINKSR stays clear on an idle link however many times it is read" {
    var part = dsi.MipiDsi.init();
    var seen: u32 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) seen |= at(&part, dsi.off.linksr);
    // The whole point of this block: the sparse register file alternated
    // 0 and all-ones here, and internal_check_link_state read the all-ones
    // as a busy sequence channel and refused the command.
    try std.testing.expectEqual(@as(u32, 0), seen);
    try std.testing.expectEqual(@as(u32, 8), part.link_reads);
}

test "video mode running is the only thing that raises VRUN" {
    var part = dsi.MipiDsi.init();
    put(&part, dsi.off.vmset0r, rule.video_control.vstart);
    try std.testing.expect(at(&part, dsi.off.linksr) & rule.link.vrun != 0);
    put(&part, dsi.off.vmset0r, rule.video_control.vstop);
    try std.testing.expect(at(&part, dsi.off.linksr) & rule.link.vrun == 0);
}

test "starting the HS clock latches CLLP2HS, which is the driver's wait" {
    var part = dsi.MipiDsi.init();
    put(&part, dsi.off.hsclksetr, rule.hs_clock.start);
    try std.testing.expect(at(&part, dsi.off.plsr) & rule.phy.cllp2hs != 0);
    try std.testing.expectEqual(@as(u32, 1), part.hs_starts);
    try std.testing.expect(at(&part, dsi.off.linksr) & rule.link.hsbusy != 0);
}

test "stopping the HS clock latches CLHS2LP and parks the lanes" {
    var part = dsi.MipiDsi.init();
    put(&part, dsi.off.hsclksetr, rule.hs_clock.start);
    put(&part, dsi.off.plscr, rule.phy.events);
    put(&part, dsi.off.hsclksetr, 0);
    const word = at(&part, dsi.off.plsr);
    try std.testing.expect(word & rule.phy.clhs2lp != 0);
    try std.testing.expect(word & rule.phy.cllp2hs == 0);
    try std.testing.expect(word & rule.phy.clstp != 0);
    try std.testing.expectEqual(@as(u32, 1), part.hs_stops);
}

test "the clock transition latches on the edge, not on every store" {
    var part = dsi.MipiDsi.init();
    put(&part, dsi.off.hsclksetr, rule.hs_clock.start);
    put(&part, dsi.off.plscr, rule.phy.events);
    put(&part, dsi.off.hsclksetr, rule.hs_clock.start | rule.hs_clock.continuous);
    try std.testing.expect(at(&part, dsi.off.plsr) & rule.phy.cllp2hs == 0);
    try std.testing.expectEqual(@as(u32, 1), part.hs_starts);
    try std.testing.expect(part.continuous());
}

test "PLSCR clears only the event bits it names" {
    var part = dsi.MipiDsi.init();
    put(&part, dsi.off.hsclksetr, rule.hs_clock.start);
    put(&part, dsi.off.hsclksetr, 0);
    put(&part, dsi.off.plscr, rule.phy.cllp2hs);
    const word = at(&part, dsi.off.plsr);
    try std.testing.expect(word & rule.phy.cllp2hs == 0);
    try std.testing.expect(word & rule.phy.clhs2lp != 0);
}

test "video start raises VIRDY and video stop raises STOP" {
    var part = dsi.MipiDsi.init();
    put(&part, dsi.off.vmset0r, rule.video_control.vstart);
    try std.testing.expect(at(&part, dsi.off.vmsr) & rule.video.virdy != 0);
    try std.testing.expect(at(&part, dsi.off.vmsr) & rule.video.running != 0);
    put(&part, dsi.off.vmset0r, rule.video_control.vstop);
    const word = at(&part, dsi.off.vmsr);
    try std.testing.expect(word & rule.video.stop != 0);
    try std.testing.expect(word & rule.video.running == 0);
    put(&part, dsi.off.vmscr, rule.video.events);
    try std.testing.expectEqual(@as(u32, 0), at(&part, dsi.off.vmsr));
    try std.testing.expectEqual(@as(u32, 1), part.video_starts);
    try std.testing.expectEqual(@as(u32, 1), part.video_stops);
}

test "a stop asked for with video idle is counted as one" {
    var part = dsi.MipiDsi.init();
    put(&part, dsi.off.vmset0r, rule.video_control.vstop);
    try std.testing.expectEqual(@as(u32, 1), part.idle_stops);
}

test "a sequence start finishes inside the store and reports both flags" {
    var part = dsi.MipiDsi.init();
    put(&part, dsi.off.hsclksetr, rule.hs_clock.start);
    put(&part, dsi.off.sqch1set0r, rule.sequence.start | rule.sequence.chsel);
    const word = at(&part, dsi.off.sqch1sr);
    try std.testing.expect(word & rule.sequence.aactfin != 0);
    try std.testing.expect(word & rule.sequence.adesfin != 0);
    try std.testing.expect(word & rule.sequence.running == 0);
    // And the link is free again straight away, so the next command passes.
    try std.testing.expect(at(&part, dsi.off.linksr) & rule.link.sq1run == 0);
    try std.testing.expectEqual(@as(u32, 1), part.sends());
    try std.testing.expectEqual(@as(u32, 0), part.darkSends());
}

test "a start with no HS clock running is counted as a dark send" {
    var part = dsi.MipiDsi.init();
    put(&part, dsi.off.sqch0set0r, rule.sequence.start);
    try std.testing.expectEqual(@as(u32, 1), part.darkSends());
}

test "a set0 store without START does not run a sequence" {
    var part = dsi.MipiDsi.init();
    put(&part, dsi.off.sqch0set0r, rule.sequence.chsel);
    try std.testing.expectEqual(@as(u32, 0), part.sends());
    try std.testing.expectEqual(@as(u32, 0), at(&part, dsi.off.sqch0sr));
    // It still reads back, the way the driver expects of a setting register.
    try std.testing.expectEqual(rule.sequence.chsel, at(&part, dsi.off.sqch0set0r));
}

test "SQCHnSCR takes the finish flags back down, per channel" {
    var part = dsi.MipiDsi.init();
    put(&part, dsi.off.sqch0set0r, rule.sequence.start);
    put(&part, dsi.off.sqch1set0r, rule.sequence.start);
    put(&part, dsi.off.sqch0scr, rule.sequence.finished);
    try std.testing.expectEqual(@as(u32, 0), at(&part, dsi.off.sqch0sr));
    try std.testing.expect(at(&part, dsi.off.sqch1sr) & rule.sequence.aactfin != 0);
}

test "ULPS enter and exit move the lane state and latch their events" {
    var part = dsi.MipiDsi.init();
    put(&part, dsi.off.ulpscr, rule.ulps.dlent);
    try std.testing.expect(at(&part, dsi.off.plsr) & rule.phy.dl0uan == 0);
    try std.testing.expect(at(&part, dsi.off.plsr) & rule.phy.dlulpent != 0);
    put(&part, dsi.off.ulpscr, rule.ulps.dlexit);
    try std.testing.expect(at(&part, dsi.off.plsr) & rule.phy.dl0uan != 0);
    try std.testing.expectEqual(@as(u32, 1), part.ulps_entries);
    try std.testing.expectEqual(@as(u32, 1), part.ulps_exits);
}

test "RSTSR holds everything down while SWRST is asserted" {
    var part = dsi.MipiDsi.init();
    try std.testing.expect(at(&part, dsi.off.rstsr) & rule.reset_status.dl0stp != 0);
    put(&part, dsi.off.rstcr, rule.reset_control.swrst);
    try std.testing.expectEqual(rule.reset_status.all_reset, at(&part, dsi.off.rstsr));
    put(&part, dsi.off.rstcr, 0);
    try std.testing.expect(at(&part, dsi.off.rstsr) & rule.reset_status.all_reset == 0);
    try std.testing.expectEqual(@as(u32, 1), part.resets);
}

test "a software reset puts the link back where reset leaves it" {
    var part = dsi.MipiDsi.init();
    put(&part, dsi.off.hsclksetr, rule.hs_clock.start);
    put(&part, dsi.off.vmset0r, rule.video_control.vstart);
    put(&part, dsi.off.sqch0set0r, rule.sequence.start);
    put(&part, dsi.off.rstcr, rule.reset_control.swrst);
    put(&part, dsi.off.rstcr, 0);
    try std.testing.expectEqual(@as(u32, 0), at(&part, dsi.off.linksr));
    try std.testing.expectEqual(@as(u32, 0), at(&part, dsi.off.vmsr));
    try std.testing.expectEqual(@as(u32, 0), at(&part, dsi.off.sqch0sr));
    try std.testing.expect(at(&part, dsi.off.plsr) & rule.phy.events == 0);
}

test "a store to a read-only status word is refused and counted" {
    var part = dsi.MipiDsi.init();
    put(&part, dsi.off.linksr, 0xFFFF_FFFF);
    put(&part, dsi.off.plsr, 0xFFFF_FFFF);
    put(&part, dsi.off.vmsr, 0xFFFF_FFFF);
    put(&part, dsi.off.rstsr, 0xFFFF_FFFF);
    put(&part, dsi.off.sqch0sr, 0xFFFF_FFFF);
    put(&part, dsi.off.sqch1sr, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 6), part.refused);
    try std.testing.expectEqual(@as(u32, 0), at(&part, dsi.off.linksr));
    try std.testing.expectEqual(@as(u32, 0), at(&part, dsi.off.vmsr));
}

test "the rest of the window is a plain shadow the driver reads back" {
    var part = dsi.MipiDsi.init();
    put(&part, 0x780, 0x1234_5678);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), at(&part, 0x780));
    put(&part, 0x210, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), at(&part, 0x210));
}

test "a narrow access is served out of the word it lands in" {
    var part = dsi.MipiDsi.init();
    put(&part, 0x160, 0xAABB_CCDD);
    try std.testing.expectEqual(@as(u32, 0xDD), part.read(base + 0x160, 1));
    try std.testing.expectEqual(@as(u32, 0xBB), part.read(base + 0x162, 1));
    try std.testing.expectEqual(@as(u32, 0xCCDD), part.read(base + 0x160, 2));
    part.write(base + 0x161, 1, 0x11);
    try std.testing.expectEqual(@as(u32, 0xAABB_11DD), at(&part, 0x160));
}

test "a byte store into a status word does not count as a poll" {
    var part = dsi.MipiDsi.init();
    part.write(base + dsi.off.linksr, 1, 0xFF);
    try std.testing.expectEqual(@as(u32, 0), part.link_reads);
    try std.testing.expect(part.refused != 0);
}

test "an access past the window is dropped rather than wrapping" {
    var part = dsi.MipiDsi.init();
    part.write(base + dsi.win_span, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), part.read(base + dsi.win_span, 4));
    try std.testing.expect(part.quiet());
}

test "the block advertises the window the bus needs" {
    var part = dsi.MipiDsi.init();
    const b = part.block();
    try std.testing.expectEqual(base, b.base);
    try std.testing.expectEqual(dsi.win_span, b.size);
    try std.testing.expectEqualStrings("MIPI-DSI", b.name);
}
