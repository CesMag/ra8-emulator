//! How long a soak run lasts (RA8EMU-186, slice 1).
//!
//! `--run-for` takes a whole number and a unit, s, m, h or d, and means
//! virtual time: 90m is ninety minutes on the board's clock however fast the
//! host gets through them, so it composes with --speed and idle-skip. The
//! longest is ten years of virtual time, past which a soak says nothing a
//! shorter one does not.
const std = @import("std");
const timebase = @import("ra8_chip").periph.timebase;

pub const Error = error{ NotANumber, NoUnit, NotPositive, TooLong };

const ns_per_s = timebase.ns_per_s;

/// Ten years of virtual time, in nanoseconds.
pub const max_ns: u64 = 3650 * 24 * 3600 * ns_per_s;

/// Virtual nanoseconds for text like "30s", "90m", "12h" or "7d".
pub fn parse(text: []const u8) Error!u64 {
    if (text.len == 0) return error.NotANumber;
    if (text[0] == '-') return error.NotPositive;
    const unit_ns: u64 = switch (text[text.len - 1]) {
        's' => ns_per_s,
        'm' => 60 * ns_per_s,
        'h' => 3600 * ns_per_s,
        'd' => 24 * 3600 * ns_per_s,
        '0'...'9' => return error.NoUnit,
        else => return error.NotANumber,
    };
    const digits = text[0 .. text.len - 1];
    if (digits.len == 0) return error.NotANumber;
    var count: u64 = 0;
    for (digits) |c| {
        if (c < '0' or c > '9') return error.NotANumber;
        count = std.math.mul(u64, count, 10) catch return error.TooLong;
        count = std.math.add(u64, count, c - '0') catch return error.TooLong;
    }
    if (count == 0) return error.NotPositive;
    const ns = std.math.mul(u64, count, unit_ns) catch return error.TooLong;
    if (ns > max_ns) return error.TooLong;
    return ns;
}

/// The cycle budget that covers `ns` of virtual time at `hz`, rounded up so
/// the run reaches the whole duration.
pub fn cycles(ns: u64, hz: u64) u64 {
    const whole = ns / ns_per_s;
    const rest = ns % ns_per_s;
    return whole * hz + (rest * hz + ns_per_s - 1) / ns_per_s;
}

/// What a bad duration gets told, in words.
pub fn describe(err: Error) []const u8 {
    return switch (err) {
        error.NotANumber => "not a duration; give a whole number and s, m, h or d, like 90m or 7d",
        error.NoUnit => "needs a unit: s, m, h or d (90m, 7d)",
        error.NotPositive => "a duration must be above zero",
        error.TooLong => "over the 3650d limit",
    };
}
