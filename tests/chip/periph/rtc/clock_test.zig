//! The calendar behind the RTC: BCD both ways, the carry chain, and what an
//! armed alarm field agrees with.
const std = @import("std");
const ra8 = @import("ra8");

const clock = ra8.chip.periph.rtc.clock;

test "bcd packs and unpacks a two-digit value" {
    try std.testing.expectEqual(@as(u8, 0x00), clock.bcd.fromBinary(0));
    try std.testing.expectEqual(@as(u8, 0x09), clock.bcd.fromBinary(9));
    try std.testing.expectEqual(@as(u8, 0x10), clock.bcd.fromBinary(10));
    try std.testing.expectEqual(@as(u8, 0x59), clock.bcd.fromBinary(59));
    try std.testing.expectEqual(@as(u8, 0), clock.bcd.toBinary(0x00));
    try std.testing.expectEqual(@as(u8, 23), clock.bcd.toBinary(0x23));
    try std.testing.expectEqual(@as(u8, 99), clock.bcd.toBinary(0x99));
}

test "a year past the century wraps, because the counter holds two digits" {
    try std.testing.expectEqual(@as(u8, 0x00), clock.bcd.fromBinary(100));
    try std.testing.expectEqual(@as(u8, 0x01), clock.bcd.fromBinary(101));
}

test "a second carries into the minute and the minute into the hour" {
    var now = clock.Calendar{ .second = 59, .minute = 59, .hour = 7 };
    now.advance();
    try std.testing.expectEqual(@as(u8, 0), now.second);
    try std.testing.expectEqual(@as(u8, 0), now.minute);
    try std.testing.expectEqual(@as(u8, 8), now.hour);
}

/// One second before midnight on the given date.
fn lastSecond(day: u8, month: u8, year: u8) clock.Calendar {
    return .{ .second = 59, .minute = 59, .hour = 23, .day = day, .month = month, .year = year };
}

test "midnight rolls the day inside a month" {
    var now = lastSecond(27, 3, 26);
    now.advance();
    try std.testing.expectEqual(@as(u8, 0), now.hour);
    try std.testing.expectEqual(@as(u8, 28), now.day);
    try std.testing.expectEqual(@as(u8, 3), now.month);
}

test "each month rolls after its own last day" {
    const ends = [_][2]u8{ .{ 31, 1 }, .{ 30, 4 }, .{ 31, 7 }, .{ 31, 8 }, .{ 30, 9 }, .{ 30, 11 } };
    for (ends) |end| {
        var now = lastSecond(end[0], end[1], 26);
        now.advance();
        try std.testing.expectEqual(@as(u8, 1), now.day);
        try std.testing.expectEqual(end[1] + 1, now.month);
    }
    var short = lastSecond(30, 4, 26);
    short.day = 29;
    short.advance();
    try std.testing.expectEqual(@as(u8, 30), short.day);
}

test "February has 28 days in a common year and 29 in a leap year" {
    var common = lastSecond(28, 2, 27);
    common.advance();
    try std.testing.expectEqual(@as(u8, 1), common.day);
    try std.testing.expectEqual(@as(u8, 3), common.month);

    var leap_eve = lastSecond(28, 2, 28);
    leap_eve.advance();
    try std.testing.expectEqual(@as(u8, 29), leap_eve.day);
    try std.testing.expectEqual(@as(u8, 2), leap_eve.month);
    leap_eve = lastSecond(29, 2, 28);
    leap_eve.advance();
    try std.testing.expectEqual(@as(u8, 1), leap_eve.day);
    try std.testing.expectEqual(@as(u8, 3), leap_eve.month);
}

test "2000 is a leap year and the counter's other leap years fall every fourth" {
    try std.testing.expect(clock.leap(0));
    try std.testing.expect(clock.leap(24));
    try std.testing.expect(!clock.leap(25));
    try std.testing.expect(!clock.leap(99));
    try std.testing.expectEqual(@as(u8, 29), clock.daysIn(2, 0));
    try std.testing.expectEqual(@as(u8, 28), clock.daysIn(2, 1));
    try std.testing.expectEqual(@as(u8, 31), clock.daysIn(0, 1));
}

test "the last second of the year carries into the next one" {
    var now = lastSecond(31, 12, 25);
    now.advance();
    try std.testing.expectEqual(@as(u8, 1), now.day);
    try std.testing.expectEqual(@as(u8, 1), now.month);
    try std.testing.expectEqual(@as(u8, 26), now.year);
    now = lastSecond(31, 12, 99);
    now.advance();
    try std.testing.expectEqual(@as(u8, 0), now.year);
}

test "reset leaves a date that exists, not the zeroth of the zeroth" {
    const now = clock.Calendar{};
    try std.testing.expectEqual(@as(u8, 1), now.day);
    try std.testing.expectEqual(@as(u8, 1), now.month);
}

test "an unarmed alarm field agrees with anything, an armed one only with its value" {
    try std.testing.expect(clock.alarm.agrees(0x00, 17));
    try std.testing.expect(clock.alarm.agrees(0x30, 17));
    try std.testing.expect(clock.alarm.agrees(0x80 | 0x17, 17));
    try std.testing.expect(!clock.alarm.agrees(0x80 | 0x17, 18));
    try std.testing.expect(clock.alarm.armed(0x80));
    try std.testing.expect(!clock.alarm.armed(0x7F));
}
