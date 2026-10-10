//! `--rtc-start`: the date and time the board's RTC is already counting
//! from when the run begins (RA8EMU-182, slice 4).
//!
//! A board with a backup battery comes up with its RTC running, so firmware
//! that checks RCR2.START before setting the time sees a clock it can keep.
//! The flag takes `YYYY-MM-DDTHH:MM:SS` (a space in place of the `T` too),
//! or `now` for the host's UTC time at launch. A seeded clock counts virtual
//! time. Without the flag the clock comes up stopped at its reset date, as
//! the corpus was recorded.
const std = @import("std");
const clock = @import("ra8_chip").periph.rtc_clock;

pub const Error = error{ BadDateTime, OutOfRange };
pub const Calendar = clock.Calendar;

/// The years the RTC's two BCD year digits can hold.
pub const first_year: u16 = 2000;
pub const last_year: u16 = 2099;

/// What `--rtc-start` asked for. `now` stays unread until the board is
/// fitted, so parsing the command line never touches the host clock.
pub const Start = union(enum) {
    now,
    at: clock.Calendar,
};

/// One `--rtc-start` value.
pub fn parse(text: []const u8) Error!Start {
    if (std.mem.eql(u8, text, "now")) return .now;
    return .{ .at = try calendar(text) };
}

/// The calendar `start` seeds the RTC with, reading the host clock for `now`.
pub fn resolve(start: Start, io: std.Io) Error!clock.Calendar {
    return switch (start) {
        .at => |at| at,
        .now => fromEpoch(@intCast(@max(std.Io.Clock.real.now(io).toSeconds(), 0))),
    };
}

fn calendar(text: []const u8) Error!clock.Calendar {
    if (text.len != "YYYY-MM-DDTHH:MM:SS".len) return Error.BadDateTime;
    for ([_]usize{ 4, 7 }) |i| if (text[i] != '-') return Error.BadDateTime;
    for ([_]usize{ 13, 16 }) |i| if (text[i] != ':') return Error.BadDateTime;
    if (text[10] != 'T' and text[10] != ' ') return Error.BadDateTime;
    return checked(
        try field(u16, text[0..4]),
        try field(u8, text[5..7]),
        try field(u8, text[8..10]),
        try field(u8, text[11..13]),
        try field(u8, text[14..16]),
        try field(u8, text[17..19]),
    );
}

/// The calendar the host's clock reads `seconds` after the Unix epoch, UTC.
pub fn fromEpoch(seconds: u64) Error!clock.Calendar {
    const epoch = std.time.epoch;
    const at = epoch.EpochSeconds{ .secs = seconds };
    const year_day = at.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = at.getDaySeconds();
    return checked(
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    );
}

/// A calendar the RTC can count from, or why not.
fn checked(year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8) Error!clock.Calendar {
    if (year < first_year or year > last_year) return Error.OutOfRange;
    const short: u8 = @intCast(year - first_year);
    if (month < 1 or month > 12) return Error.OutOfRange;
    if (day < 1 or day > clock.daysIn(month, short)) return Error.OutOfRange;
    if (hour > 23 or minute > 59 or second > 59) return Error.OutOfRange;
    return .{ .second = second, .minute = minute, .hour = hour, .day = day, .month = month, .year = short };
}

fn field(comptime T: type, digits: []const u8) Error!T {
    for (digits) |c| if (!std.ascii.isDigit(c)) return Error.BadDateTime;
    return std.fmt.parseInt(T, digits, 10) catch Error.BadDateTime;
}
