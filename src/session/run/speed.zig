//! The speed factor a run asks for (RA8EMU-184, slice 1).
//!
//! A factor is kept in thousandths of real time, the unit the pacer works in
//! (src/session/run/pacer.zig): 1000 is 1x, 250 is 0.25x, 5000 is 5x. Text
//! takes any positive decimal with up to three places, or `max` for an
//! unpaced run, which is what a run without the flag already is.
const std = @import("std");

pub const Error = error{ NotANumber, NotPositive, TooFine, TooFast };

/// The fastest factor that can be asked for: a million times real time. Past
/// that no host keeps up and the run is unpaced in all but name.
pub const max_milli: u64 = 1_000_000 * 1000;

/// Thousandths of real time, or null for `max`.
pub fn parse(text: []const u8) Error!?u64 {
    if (std.mem.eql(u8, text, "max")) return null;
    if (text.len > 0 and text[0] == '-') return error.NotPositive;
    const dot = std.mem.indexOfScalar(u8, text, '.');
    const whole_text = text[0 .. dot orelse text.len];
    const frac_text = if (dot) |at| text[at + 1 ..] else "";
    if (whole_text.len == 0 and frac_text.len == 0) return error.NotANumber;
    if (frac_text.len > 3) return error.TooFine;
    const whole = try digits(whole_text);
    var frac = try digits(frac_text);
    for (frac_text.len..3) |_| frac *= 10;
    if (whole > max_milli / 1000) return error.TooFast;
    const milli = whole * 1000 + frac;
    if (milli == 0) return error.NotPositive;
    if (milli > max_milli) return error.TooFast;
    return milli;
}

/// What a bad factor gets told, in words.
pub fn describe(err: Error) []const u8 {
    return switch (err) {
        error.NotANumber => "not a number; give a factor like 0.25, 1 or 100, or max",
        error.NotPositive => "a speed must be above zero",
        error.TooFine => "at most three decimal places (0.001x is the finest step)",
        error.TooFast => "over the 1000000x limit; use max for an unpaced run",
    };
}

fn digits(text: []const u8) Error!u64 {
    var value: u64 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return error.NotANumber;
        value = std.math.mul(u64, value, 10) catch return error.TooFast;
        value = std.math.add(u64, value, c - '0') catch return error.TooFast;
    }
    return value;
}
