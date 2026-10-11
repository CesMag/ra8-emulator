//! Tests for src/session/rtc/rtc.zig (RA8EMU-809): BCD counters decode
//! to a checked date, and anything no calendar has decodes to null.
const std = @import("std");
const ra8 = @import("ra8");

const session_rtc = ra8.session.rtc;

fn counters(year: u8, month: u8, day: u8, hour: u8, minute: u8, second: u8) session_rtc.Counters {
    return .{ .year = year, .month = month, .day = day, .hour = hour, .minute = minute, .second = second, .running = true };
}

test "BCD counters decode and format as yyyy-mm-dd hh:mm:ss" {
    const date = session_rtc.decode(counters(0x26, 0x10, 0x08, 0x09, 0x47, 0x05)) orelse return error.NoDate;
    var text: [19]u8 = undefined;
    try std.testing.expectEqualStrings("2026-10-08 09:47:05", date.format(&text));
}

test "a digit over 9 is not BCD and holds no date" {
    try std.testing.expectEqual(@as(?u8, null), session_rtc.fromBcd(0x1A));
    try std.testing.expectEqual(@as(?u8, 59), session_rtc.fromBcd(0x59));
    try std.testing.expect(session_rtc.decode(counters(0x26, 0x10, 0x08, 0x09, 0x4A, 0x00)) == null);
}

test "out-of-range fields hold no date" {
    try std.testing.expect(session_rtc.decode(counters(0x26, 0x13, 0x01, 0x00, 0x00, 0x00)) == null);
    try std.testing.expect(session_rtc.decode(counters(0x26, 0x00, 0x01, 0x00, 0x00, 0x00)) == null);
    try std.testing.expect(session_rtc.decode(counters(0x26, 0x01, 0x00, 0x00, 0x00, 0x00)) == null);
    try std.testing.expect(session_rtc.decode(counters(0x26, 0x01, 0x01, 0x24, 0x00, 0x00)) == null);
    try std.testing.expect(session_rtc.decode(counters(0x26, 0x01, 0x01, 0x00, 0x60, 0x00)) == null);
    try std.testing.expect(session_rtc.decode(counters(0x26, 0x04, 0x31, 0x00, 0x00, 0x00)) == null);
}

test "February 29 exists in leap years only, 2000 included" {
    try std.testing.expect(session_rtc.decode(counters(0x00, 0x02, 0x29, 0x00, 0x00, 0x00)) != null);
    try std.testing.expect(session_rtc.decode(counters(0x28, 0x02, 0x29, 0x00, 0x00, 0x00)) != null);
    try std.testing.expect(session_rtc.decode(counters(0x26, 0x02, 0x29, 0x00, 0x00, 0x00)) == null);
}
