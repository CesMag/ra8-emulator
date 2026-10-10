//! The RTC register window: the counters, the run gate over them, and the
//! alarm edge.
const std = @import("std");
const ra8 = @import("ra8");

const rtc = ra8.chip.periph.rtc;

fn read8(unit: *rtc.Rtc, offset: u32) u8 {
    return @truncate(unit.read(rtc.win_base + offset, 1));
}

fn write8(unit: *rtc.Rtc, offset: u32, value: u8) void {
    unit.write(rtc.win_base + offset, 1, value);
}

/// Stop the clock, set the time, arm nothing. The order firmware uses.
fn setTime(unit: *rtc.Rtc, hour: u8, minute: u8, second: u8) void {
    write8(unit, rtc.off.rcr2, 0);
    write8(unit, rtc.off.hrcnt, hour);
    write8(unit, rtc.off.mincnt, minute);
    write8(unit, rtc.off.seccnt, second);
}

test "reset publishes a date that exists and a stopped clock holds it" {
    var unit = rtc.Rtc.init();
    try std.testing.expectEqual(@as(u8, 0x01), read8(&unit, rtc.off.daycnt));
    try std.testing.expectEqual(@as(u8, 0x01), read8(&unit, rtc.off.moncnt));
    unit.tick();
    unit.tick();
    try std.testing.expectEqual(@as(u8, 0x00), read8(&unit, rtc.off.seccnt));
    try std.testing.expectEqual(@as(u32, 0), unit.seconds);
    try std.testing.expect(unit.quiet());
}

test "a control write reads back, which is what the bring-up poll waits on" {
    var unit = rtc.Rtc.init();
    write8(&unit, rtc.off.rcr2, 0x40);
    try std.testing.expectEqual(@as(u8, 0x40), read8(&unit, rtc.off.rcr2));
    write8(&unit, rtc.off.rcr1, rtc.control.aie | rtc.control.pie);
    try std.testing.expectEqual(@as(u8, 0x05), read8(&unit, rtc.off.rcr1));
}

test "the counters advance in BCD once START is set" {
    var unit = rtc.Rtc.init();
    setTime(&unit, 0x11, 0x59, 0x58);
    write8(&unit, rtc.off.rcr2, rtc.control.start);
    unit.tick();
    try std.testing.expectEqual(@as(u8, 0x59), read8(&unit, rtc.off.seccnt));
    unit.tick();
    try std.testing.expectEqual(@as(u8, 0x00), read8(&unit, rtc.off.seccnt));
    try std.testing.expectEqual(@as(u8, 0x00), read8(&unit, rtc.off.mincnt));
    try std.testing.expectEqual(@as(u8, 0x12), read8(&unit, rtc.off.hrcnt));
    try std.testing.expectEqual(@as(u32, 2), unit.seconds);
}

test "a counter write while the clock runs is refused, not taken like dev" {
    var unit = rtc.Rtc.init();
    setTime(&unit, 0x08, 0x00, 0x00);
    write8(&unit, rtc.off.rcr2, rtc.control.start);
    write8(&unit, rtc.off.hrcnt, 0x23);
    try std.testing.expectEqual(@as(u32, 1), unit.refused_running);
    try std.testing.expectEqual(@as(u8, 0x08), read8(&unit, rtc.off.hrcnt));
    try std.testing.expectEqual(@as(u8, 8), unit.now.hour);
    // Stopped, the same write lands and reseeds the running time.
    write8(&unit, rtc.off.rcr2, 0);
    write8(&unit, rtc.off.hrcnt, 0x23);
    try std.testing.expectEqual(@as(u8, 0x23), read8(&unit, rtc.off.hrcnt));
    try std.testing.expectEqual(@as(u8, 23), unit.now.hour);
    try std.testing.expectEqual(@as(u32, 1), unit.refused_running);
}

test "R64CNT is read-only, where dev takes the store" {
    var unit = rtc.Rtc.init();
    write8(&unit, rtc.off.r64cnt, 0x2A);
    try std.testing.expectEqual(@as(u32, 1), unit.refused_read_only);
    try std.testing.expectEqual(@as(u8, 0x00), read8(&unit, rtc.off.r64cnt));
    write8(&unit, rtc.off.rcr2, rtc.control.start);
    unit.tick();
    try std.testing.expectEqual(@as(u8, 0x01), read8(&unit, rtc.off.r64cnt));
}

test "an alarm raises once on the match, not every second it stays matched" {
    var unit = rtc.Rtc.init();
    setTime(&unit, 0x10, 0x30, 0x00);
    // Hour only: dev would re-raise for every second of the hour.
    write8(&unit, rtc.off.hrar, 0x80 | 0x10);
    write8(&unit, rtc.off.rcr1, rtc.control.aie);
    write8(&unit, rtc.off.rcr2, rtc.control.start);
    var ticks: u32 = 0;
    while (ticks < 5) : (ticks += 1) unit.tick();
    try std.testing.expectEqual(@as(u32, 1), unit.matches);
    try std.testing.expectEqual(@as(u32, 1), unit.alarms);
}

test "the alarm event is offered once and the boundary takes it" {
    var unit = rtc.Rtc.init();
    setTime(&unit, 0x00, 0x00, 0x04);
    write8(&unit, rtc.off.secar, 0x80 | 0x05);
    write8(&unit, rtc.off.rcr1, rtc.control.aie);
    write8(&unit, rtc.off.rcr2, rtc.control.start);
    unit.tick();
    const due = unit.dueEvents();
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expectEqual(rtc.event.alarm, due.constSlice()[0]);
    try std.testing.expectEqual(@as(usize, 0), unit.dueEvents().len);
}

test "a match with AIE clear is counted but raises nothing" {
    var unit = rtc.Rtc.init();
    setTime(&unit, 0x00, 0x00, 0x00);
    write8(&unit, rtc.off.secar, 0x80 | 0x01);
    write8(&unit, rtc.off.rcr2, rtc.control.start);
    unit.tick();
    try std.testing.expectEqual(@as(u32, 1), unit.matches);
    try std.testing.expectEqual(@as(u32, 0), unit.alarms);
    try std.testing.expectEqual(@as(usize, 0), unit.dueEvents().len);
}

test "the alarm re-arms once the time moves off the match" {
    var unit = rtc.Rtc.init();
    setTime(&unit, 0x00, 0x00, 0x58);
    write8(&unit, rtc.off.secar, 0x80 | 0x00);
    write8(&unit, rtc.off.rcr1, rtc.control.aie);
    write8(&unit, rtc.off.rcr2, rtc.control.start);
    var ticks: u32 = 0;
    while (ticks < 121) : (ticks += 1) unit.tick();
    try std.testing.expectEqual(@as(u32, 2), unit.alarms);
}

test "the day and month alarms take part, where dev ignores them" {
    var unit = rtc.Rtc.init();
    setTime(&unit, 0x00, 0x00, 0x58);
    write8(&unit, rtc.off.secar, 0x80 | 0x00);
    write8(&unit, rtc.off.dayar, 0x80 | 0x02);
    write8(&unit, rtc.off.rcr1, rtc.control.aie);
    write8(&unit, rtc.off.rcr2, rtc.control.start);
    // Second 00 comes round twice inside this window, both of them on the
    // first of the month. dev compares only hh:mm:ss, so it would raise on
    // each; the armed day is what holds them back here.
    var ticks: u32 = 0;
    while (ticks < 122) : (ticks += 1) unit.tick();
    try std.testing.expectEqual(@as(u32, 0), unit.alarms);
    try std.testing.expectEqual(@as(u8, 1), unit.now.day);
    // The same second, on the armed day, is the alarm.
    write8(&unit, rtc.off.rcr2, 0);
    write8(&unit, rtc.off.daycnt, 0x02);
    write8(&unit, rtc.off.seccnt, 0x58);
    write8(&unit, rtc.off.rcr2, rtc.control.start);
    ticks = 0;
    while (ticks < 2) : (ticks += 1) unit.tick();
    try std.testing.expectEqual(@as(u32, 1), unit.alarms);
    try std.testing.expectEqual(@as(u8, 2), unit.now.day);
}

test "an armed year alarm needs RYRAREN, and disagrees on the wrong year" {
    var unit = rtc.Rtc.init();
    setTime(&unit, 0x00, 0x00, 0x00);
    write8(&unit, rtc.off.secar, 0x80 | 0x01);
    write8(&unit, rtc.off.yrar, 0x26);
    write8(&unit, rtc.off.yraren, 0x80);
    write8(&unit, rtc.off.rcr1, rtc.control.aie);
    write8(&unit, rtc.off.rcr2, rtc.control.start);
    unit.tick();
    try std.testing.expectEqual(@as(u32, 0), unit.alarms);
    // Set the year to the armed one and the same second matches.
    write8(&unit, rtc.off.rcr2, 0);
    write8(&unit, rtc.off.yrcnt, 0x26);
    write8(&unit, rtc.off.seccnt, 0x00);
    write8(&unit, rtc.off.rcr2, rtc.control.start);
    unit.tick();
    try std.testing.expectEqual(@as(u32, 1), unit.alarms);
}

test "an alarm nobody armed never matches a zeroed register file" {
    var unit = rtc.Rtc.init();
    write8(&unit, rtc.off.rcr1, rtc.control.aie);
    write8(&unit, rtc.off.rcr2, rtc.control.start);
    var ticks: u32 = 0;
    while (ticks < 10) : (ticks += 1) unit.tick();
    try std.testing.expect(!unit.armed());
    try std.testing.expectEqual(@as(u32, 0), unit.matches);
}

test "PIE offers one periodic event per modelled second" {
    var unit = rtc.Rtc.init();
    write8(&unit, rtc.off.rcr1, rtc.control.pie);
    write8(&unit, rtc.off.rcr2, rtc.control.start);
    unit.tick();
    const due = unit.dueEvents();
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expectEqual(rtc.event.periodic, due.constSlice()[0]);
    unit.tick();
    unit.tick();
    try std.testing.expectEqual(@as(u32, 3), unit.periodics);
}

test "an alarm and a periodic in the same second are both offered" {
    var unit = rtc.Rtc.init();
    setTime(&unit, 0x00, 0x00, 0x00);
    write8(&unit, rtc.off.secar, 0x80 | 0x01);
    write8(&unit, rtc.off.rcr1, rtc.control.aie | rtc.control.pie);
    write8(&unit, rtc.off.rcr2, rtc.control.start);
    unit.tick();
    const due = unit.dueEvents();
    try std.testing.expectEqual(@as(usize, 2), due.len);
    try std.testing.expectEqual(rtc.event.alarm, due.constSlice()[0]);
    try std.testing.expectEqual(rtc.event.periodic, due.constSlice()[1]);
}

test "a halfword store lands on both bytes, and the window rejects an address past it" {
    var unit = rtc.Rtc.init();
    unit.write(rtc.win_base + rtc.off.secar, 2, 0x8515);
    try std.testing.expectEqual(@as(u8, 0x15), read8(&unit, rtc.off.secar));
    try std.testing.expectEqual(@as(u8, 0x85), read8(&unit, rtc.off.secar + 1));
    unit.write(rtc.win_base + rtc.win_span, 1, 0xFF);
    try std.testing.expectEqual(@as(u32, 0), unit.read(rtc.win_base + rtc.win_span, 1));
}

test "the block answers for its own window" {
    var unit = rtc.Rtc.init();
    const block = unit.block();
    try std.testing.expectEqual(rtc.win_base, block.base);
    try std.testing.expectEqual(rtc.win_span, block.size);
    try std.testing.expect(block.covers(rtc.win_base + rtc.off.rcr2));
    try std.testing.expect(!block.covers(rtc.win_base + rtc.win_span));
    block.writeFn(block.context, rtc.win_base + rtc.off.rcr2, 1, rtc.control.start);
    try std.testing.expect(unit.running());
}
