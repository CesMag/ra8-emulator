//! Covers src/chip/periph/rtc/source.zig: RCR4.RCKSEL picks the count source, and
//! the order it is picked in is judged against the software reset.
const std = @import("std");
const ra8 = @import("ra8");
const rtc = ra8.chip.periph.rtc;
const source = ra8.chip.periph.rtc.source;

fn store(unit: *rtc.Rtc, offset: u32, byte: u8) void {
    unit.write(rtc.win_base + offset, 1, byte);
}

test "RCKSEL picks the count source out of the byte the store carries" {
    var select = source.Select{};
    try std.testing.expect(select.quiet());
    try std.testing.expectEqual(source.Source.subclock, select.source);

    select.select(source.rcksel);
    try std.testing.expectEqual(source.Source.loco, select.source);
    try std.testing.expect(select.chosen);
    try std.testing.expect(!select.quiet());

    select.select(0);
    try std.testing.expectEqual(source.Source.subclock, select.source);
}

test "a source selected before the initial settings is the driver's order" {
    var select = source.Select{};
    select.select(source.rcksel);
    select.initialise();
    try std.testing.expectEqual(@as(u32, 0), select.late);
    try std.testing.expectEqual(@as(u32, 0), select.unsourced);
}

test "a source selected after the initial settings is counted" {
    var select = source.Select{};
    select.select(0);
    select.initialise();
    select.select(source.rcksel);
    try std.testing.expectEqual(@as(u32, 1), select.late);
    // The byte still lands: the source really is the LOCO now.
    try std.testing.expectEqual(source.Source.loco, select.source);
}

test "a reset with no source ever selected is counted" {
    var select = source.Select{};
    select.initialise();
    try std.testing.expectEqual(@as(u32, 1), select.unsourced);
    try std.testing.expect(!select.chosen);
    try std.testing.expect(!select.quiet());
}

test "the source names itself for the report" {
    try std.testing.expectEqualStrings("sub-clock", source.Source.subclock.name());
    try std.testing.expectEqualStrings("LOCO", source.Source.loco.name());
}

test "the RTC takes RCR4 through the select and still reads it back" {
    var unit = rtc.Rtc.init();
    store(&unit, rtc.off.rcr4, source.rcksel);
    try std.testing.expectEqual(source.Source.loco, unit.count_source.source);
    try std.testing.expectEqual(@as(u32, source.rcksel), unit.read(rtc.win_base + rtc.off.rcr4, 1));
    try std.testing.expect(!unit.quiet());
}

test "the driver's own clock bring-up order is quiet on both rules" {
    var unit = rtc.Rtc.init();
    // RCR4 first, then the prescaler stop, then the software reset.
    store(&unit, rtc.off.rcr4, 0);
    store(&unit, rtc.off.rcr2, 0);
    store(&unit, rtc.off.rcr2, ra8.chip.periph.rtc.reset.mask.reset);
    try std.testing.expectEqual(@as(u32, 0), unit.count_source.late);
    try std.testing.expectEqual(@as(u32, 0), unit.count_source.unsourced);
    try std.testing.expect(unit.count_source.settled);
}

test "a bring-up that skips RCR4 is counted at the reset" {
    var unit = rtc.Rtc.init();
    store(&unit, rtc.off.rcr2, ra8.chip.periph.rtc.reset.mask.reset);
    try std.testing.expectEqual(@as(u32, 1), unit.count_source.unsourced);
    // And swapping the source afterwards is the late store.
    store(&unit, rtc.off.rcr4, source.rcksel);
    try std.testing.expectEqual(@as(u32, 1), unit.count_source.late);
}
