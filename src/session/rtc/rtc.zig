//! The board's RTC calendar as the debugger reads it (RA8EMU-809).
//!
//! The time bar wants the date the guest would read, taken in one go. Six
//! memory reads of a running counter can straddle a tick, and a read wider
//! than a word over the peripheral window is refused (RA8EMU-938), so the
//! serving side hands over the six BCD counters as one snapshot and this
//! file decodes them. Counters that are not valid BCD, or that name a date
//! no calendar has, decode to null rather than to a guess.
const std = @import("std");

/// The calendar counters exactly as the guest reads them, in BCD.
pub const Counters = struct {
    second: u8,
    minute: u8,
    hour: u8,
    day: u8,
    month: u8,
    /// The low BCD pair of a 2000-based year.
    year: u8,
    /// RCR2.START: whether the counters are advancing.
    running: bool,
};

/// A decoded, checked calendar date and time.
pub const Calendar = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,

    /// "yyyy-mm-dd hh:mm:ss", the time bar's readout.
    pub fn format(self: Calendar, into: *[19]u8) []const u8 {
        return std.fmt.bufPrint(into, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
            self.year, self.month, self.day, self.hour, self.minute, self.second,
        }) catch unreachable;
    }
};

/// Board-specific code supplies the counter snapshot.
pub const Clock = struct {
    context: *anyopaque,
    countersFn: *const fn (*anyopaque) Counters,

    pub fn counters(self: Clock) Counters {
        return self.countersFn(self.context);
    }
};

/// The binary value of a BCD byte, or null when either digit is over 9.
pub fn fromBcd(value: u8) ?u8 {
    const high = value >> 4;
    const low = value & 0x0F;
    if (high > 9 or low > 9) return null;
    return high * 10 + low;
}

/// The date the counters hold, or null when they hold none.
pub fn decode(raw: Counters) ?Calendar {
    const second = fromBcd(raw.second) orelse return null;
    const minute = fromBcd(raw.minute) orelse return null;
    const hour = fromBcd(raw.hour) orelse return null;
    const day = fromBcd(raw.day) orelse return null;
    const month = fromBcd(raw.month) orelse return null;
    const year = fromBcd(raw.year) orelse return null;
    if (second > 59 or minute > 59 or hour > 23) return null;
    if (month < 1 or month > 12) return null;
    if (day < 1 or day > daysIn(month, year)) return null;
    return .{ .year = 2000 + @as(u16, year), .month = month, .day = day, .hour = hour, .minute = minute, .second = second };
}

/// Days in `month` of the 2000-based `year`; every fourth year is a leap
/// year in 2000..2099, 2000 included.
fn daysIn(month: u8, year: u8) u8 {
    return switch (month) {
        2 => if (year % 4 == 0) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}
