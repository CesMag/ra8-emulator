//! The RTC's calendar: the time the counters publish, and what an armed
//! alarm is matched against.
//!
//! The register window next door in rtc.zig is a byte shadow the firmware
//! reads in BCD. The running time is kept here in binary instead, because
//! everything the model has to decide (has a second elapsed, has the alarm
//! come round, has the day rolled) is arithmetic, and doing it on packed BCD
//! is how a calendar model grows a bug it cannot see.
//!
//! Months have their real lengths and February has 29 days in a leap year
//! (RA8EMU-182; dev's board_periph_rtc.c made every month 28 days, which
//! this replaces). The year is the 2000-based low BCD pair the counter
//! carries, so it spans 2000 to 2099, where every fourth year is a leap
//! year without exception: 2000 is one (divisible by 400) and 2100, the
//! first century year that is not, is past the counter's reach.
const std = @import("std");

/// Calendar moduli. The day and month ones are the model's own rule above.
pub const limit = struct {
    pub const seconds_per_minute: u8 = 60;
    pub const minutes_per_hour: u8 = 60;
    pub const hours_per_day: u8 = 24;
    pub const months_per_year: u8 = 12;
    /// The counter holds two BCD digits, so it wraps a century.
    pub const years_per_century: u8 = 100;
};

/// Days in each month of a common year, January first.
const month_days = [12]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

/// Whether a 2000-based counter year is a leap year. Exact across the
/// counter's whole century; see the header.
pub fn leap(year: u8) bool {
    return year % 4 == 0;
}

/// The days in `month` (1 to 12) of `year`. A month the counter should
/// never hold answers 31, so a stray value still rolls rather than sticking.
pub fn daysIn(month: u8, year: u8) u8 {
    if (month == 0 or month > limit.months_per_year) return 31;
    if (month == 2 and leap(year)) return 29;
    return month_days[month - 1];
}

/// Packed BCD, the form every calendar and alarm register is read and
/// written in.
pub const bcd = struct {
    pub const base: u8 = 10;
    pub const shift: u3 = 4;
    pub const nibble: u8 = 0x0F;

    pub fn fromBinary(value: u8) u8 {
        const wrapped = value % limit.years_per_century;
        return ((wrapped / base) << shift) | (wrapped % base);
    }

    /// A nibble above 9 is not a digit. Firmware that writes one has written
    /// a value the counter cannot hold, so the tens nibble is taken as it
    /// stands rather than folded into a plausible-looking number.
    pub fn toBinary(value: u8) u8 {
        const tens = (value >> shift) & nibble;
        const units = value & nibble;
        return tens *% base +% units;
    }
};

/// One alarm register: an enable bit over a BCD value. A field whose enable
/// is clear takes no part in the match, which is how a single alarm can mean
/// "every minute at :30" or "once, at this date and time".
pub const alarm = struct {
    pub const enable: u8 = 0x80;
    pub const value: u8 = 0x7F;

    pub fn armed(register: u8) bool {
        return register & enable != 0;
    }

    /// True when this field does not object: either it is not armed, or the
    /// value under it is the time now.
    pub fn agrees(register: u8, now: u8) bool {
        if (!armed(register)) return true;
        return bcd.toBinary(register & value) == now;
    }
};

/// The running time, in binary. Reset leaves it at the first day of the
/// first month: dev zeroes the whole struct and reports a 00-00 date no
/// calendar has, and a driver that reads the counters before setting them
/// should get a date that at least exists.
pub const Calendar = struct {
    second: u8 = 0,
    minute: u8 = 0,
    hour: u8 = 0,
    day: u8 = 1,
    month: u8 = 1,
    /// 2000-based, the low BCD pair the year counter carries.
    year: u8 = 0,

    /// Move the clock on by one second, carrying through every field.
    pub fn advance(self: *Calendar) void {
        self.second += 1;
        if (self.second < limit.seconds_per_minute) return;
        self.second = 0;
        self.minute += 1;
        if (self.minute < limit.minutes_per_hour) return;
        self.minute = 0;
        self.hour += 1;
        if (self.hour < limit.hours_per_day) return;
        self.hour = 0;
        self.day += 1;
        if (self.day <= daysIn(self.month, self.year)) return;
        self.day = 1;
        self.month += 1;
        if (self.month <= limit.months_per_year) return;
        self.month = 1;
        self.year = (self.year + 1) % limit.years_per_century;
    }
};
