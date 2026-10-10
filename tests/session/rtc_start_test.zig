//! Tests for src/session/rtc_start.zig, through the flag that uses it,
//! and for the RTC it seeds.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const parse = cli_app.cli.parse;
const rtc = ra8.chip.periph.rtc;

fn start(value: []const u8) !?ra8.session.rtc_start.Calendar {
    const options = try parse(&[_][]const u8{ "emu", "a.elf", "--rtc-start", value });
    const given = options.rtc_start orelse return null;
    return given.at;
}

test "a run with no --rtc-start leaves the RTC at its reset date" {
    const options = try parse(&[_][]const u8{ "emu", "a.elf" });
    try std.testing.expect(options.rtc_start == null);
}

test "--rtc-start takes an ISO-8601 date and time" {
    const at = (try start("2026-10-04T05:33:50")).?;
    try std.testing.expectEqual(@as(u8, 26), at.year);
    try std.testing.expectEqual(@as(u8, 10), at.month);
    try std.testing.expectEqual(@as(u8, 4), at.day);
    try std.testing.expectEqual(@as(u8, 5), at.hour);
    try std.testing.expectEqual(@as(u8, 33), at.minute);
    try std.testing.expectEqual(@as(u8, 50), at.second);
    const spaced = (try start("2099-12-31 23:59:59")).?;
    try std.testing.expectEqual(@as(u8, 99), spaced.year);
}

test "--rtc-start knows Feb 29 only in a leap year" {
    try std.testing.expectEqual(@as(u8, 29), (try start("2028-02-29T00:00:00")).?.day);
    try std.testing.expectError(error.OutOfRange, start("2026-02-29T00:00:00"));
}

test "--rtc-start refuses what the RTC cannot count" {
    try std.testing.expectError(error.OutOfRange, start("1999-12-31T23:59:59"));
    try std.testing.expectError(error.OutOfRange, start("2100-01-01T00:00:00"));
    try std.testing.expectError(error.OutOfRange, start("2026-13-01T00:00:00"));
    try std.testing.expectError(error.OutOfRange, start("2026-04-31T00:00:00"));
    try std.testing.expectError(error.OutOfRange, start("2026-10-04T24:00:00"));
    try std.testing.expectError(error.BadDateTime, start("2026-10-04"));
    try std.testing.expectError(error.BadDateTime, start("2026/10/04T00:00:00"));
    try std.testing.expectError(error.BadDateTime, start("2026-1x-04T00:00:00"));
}

test "--rtc-start now reads the host clock when the board is fitted" {
    const options = try parse(&[_][]const u8{ "emu", "a.elf", "--rtc-start", "now" });
    try std.testing.expect(options.rtc_start.? == .now);
    const at = try ra8.session.rtc_start.resolve(options.rtc_start.?, std.testing.io);
    try std.testing.expect(at.year >= 26);
    try std.testing.expect(at.month >= 1 and at.month <= 12);
}

test "a seeded RTC is running at that time and counts virtual seconds" {
    var unit = rtc.Rtc.init();
    unit.seed(.{ .second = 59, .minute = 59, .hour = 23, .day = 31, .month = 12, .year = 26 });
    try std.testing.expect(unit.running());
    try std.testing.expectEqual(rtc.pace.Mode.virtual, unit.pace.mode);
    try std.testing.expectEqual(@as(u32, 0x59), unit.read(rtc.win_base + rtc.off.seccnt, 1));
    unit.tickFor(1_000_000_000);
    try std.testing.expectEqual(@as(u32, 0x27), unit.read(rtc.win_base + rtc.off.yrcnt, 1));
    try std.testing.expectEqual(@as(u32, 0x01), unit.read(rtc.win_base + rtc.off.moncnt, 1));
    try std.testing.expectEqual(@as(u32, 0x00), unit.read(rtc.win_base + rtc.off.seccnt, 1));
}
