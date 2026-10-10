const std = @import("std");
const ra8 = @import("ra8");

const reset = ra8.chip.periph.rtc_reset;
const rtc = ra8.chip.periph.rtc;

test "RCR2 sits where the register file puts it" {
    try std.testing.expectEqual(@as(u32, 0x24), reset.off_rcr2);
    try std.testing.expectEqual(reset.off_rcr2, rtc.off.rcr2);
}

test "the bit positions are the header's own" {
    try std.testing.expectEqual(@as(u8, 1 << 0), reset.mask.start);
    try std.testing.expectEqual(@as(u8, 1 << 1), reset.mask.reset);
    try std.testing.expectEqual(@as(u8, 1 << 2), reset.mask.adj30);
    try std.testing.expectEqual(@as(u8, 1 << 3), reset.mask.rtcoe);
    try std.testing.expectEqual(@as(u8, 1 << 4), reset.mask.aadje);
    try std.testing.expectEqual(@as(u8, 1 << 5), reset.mask.aadjp);
    try std.testing.expectEqual(@as(u8, 1 << 6), reset.mask.hr24);
    try std.testing.expectEqual(@as(u8, 1 << 7), reset.mask.cntmd);
}

test "a store with the bit set asks for the reset" {
    try std.testing.expect(reset.requested(reset.mask.reset));
    try std.testing.expect(reset.requested(0xFF));
    try std.testing.expect(!reset.requested(0));
    try std.testing.expect(!reset.requested(reset.mask.start | reset.mask.hr24));
}

test "the command bit never lands, and the rest of the byte does" {
    try std.testing.expectEqual(@as(u8, 0), reset.stored(reset.mask.reset));
    try std.testing.expectEqual(
        @as(u8, reset.mask.start | reset.mask.hr24),
        reset.stored(reset.mask.start | reset.mask.reset | reset.mask.hr24),
    );
    try std.testing.expectEqual(@as(u8, 0xFD), reset.stored(0xFF));
    try std.testing.expectEqual(@as(u8, 0x40), reset.stored(0x40));
}

test "START says whether the counters advance" {
    try std.testing.expect(reset.running(reset.mask.start));
    try std.testing.expect(!reset.running(reset.mask.hr24));
    try std.testing.expect(!reset.running(0));
}

test "HR24 is read back by the driver, so it is read here" {
    try std.testing.expect(reset.hours24(0x40));
    try std.testing.expect(!reset.hours24(reset.mask.start));
}

test "CNTMD picks what the counters count in" {
    try std.testing.expectEqual(reset.Mode.calendar, reset.Mode.of(0));
    try std.testing.expectEqual(reset.Mode.calendar, reset.Mode.of(reset.mask.start));
    try std.testing.expectEqual(reset.Mode.binary, reset.Mode.of(reset.mask.cntmd));
    try std.testing.expectEqualStrings("calendar", reset.Mode.of(0).name());
    try std.testing.expectEqualStrings("binary", reset.Mode.of(0x80).name());
}

fn write8(unit: *rtc.Rtc, offset: u32, byte: u8) void {
    unit.write(rtc.win_base + offset, 1, byte);
}

fn read8(unit: *rtc.Rtc, offset: u32) u8 {
    return @truncate(unit.read(rtc.win_base + offset, 1));
}

test "the driver's reset poll falls through instead of spinning" {
    var unit = rtc.Rtc.init();
    write8(&unit, rtc.off.rcr2, reset.mask.reset);
    try std.testing.expectEqual(@as(u8, 0), read8(&unit, rtc.off.rcr2));
    try std.testing.expectEqual(@as(u32, 1), unit.resets);
}

test "a reset clears the sub-second prescaler and leaves the calendar alone" {
    var unit = rtc.Rtc.init();
    write8(&unit, rtc.off.hrcnt, 0x12);
    write8(&unit, rtc.off.rcr2, reset.mask.start);
    unit.tick();
    try std.testing.expect(read8(&unit, rtc.off.r64cnt) != 0);

    write8(&unit, rtc.off.rcr2, reset.mask.reset);
    try std.testing.expectEqual(@as(u8, 0), read8(&unit, rtc.off.r64cnt));
    try std.testing.expectEqual(@as(u8, 0x12), read8(&unit, rtc.off.hrcnt));
}

test "the reset stops the count, because the bit it asked for was alone" {
    var unit = rtc.Rtc.init();
    write8(&unit, rtc.off.rcr2, reset.mask.start);
    try std.testing.expect(unit.running());
    write8(&unit, rtc.off.rcr2, reset.mask.reset);
    try std.testing.expect(!unit.running());
}

test "a control write that never sets the bit resets nothing" {
    var unit = rtc.Rtc.init();
    write8(&unit, rtc.off.rcr2, 0x40);
    try std.testing.expectEqual(@as(u8, 0x40), read8(&unit, rtc.off.rcr2));
    try std.testing.expectEqual(@as(u32, 0), unit.resets);
    try std.testing.expect(unit.quiet());
}

test "resets are counted, and a counted reset is not a quiet run" {
    var unit = rtc.Rtc.init();
    write8(&unit, rtc.off.rcr2, reset.mask.reset);
    write8(&unit, rtc.off.rcr2, reset.mask.reset | reset.mask.hr24);
    try std.testing.expectEqual(@as(u32, 2), unit.resets);
    try std.testing.expectEqual(@as(u8, 0x40), read8(&unit, rtc.off.rcr2));
    try std.testing.expect(!unit.quiet());
}
