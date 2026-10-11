//! Fixed-cadence instruction widths at an image core-clock rate.
const std = @import("std");
const clocks = @import("ra8_chip").periph.clocks;

pub fn instructions(cycles: u64, hz: u64, remainder: u64) u64 {
    const fixed_hz = clocks.timebase.default_hz;
    var whole = std.math.mul(u64, cycles / hz, fixed_hz) catch return std.math.maxInt(u64);
    const rest = std.math.mul(u64, cycles % hz, fixed_hz) catch return std.math.maxInt(u64);
    if (rest >= remainder) {
        const partial = std.math.divCeil(u64, rest - remainder, hz) catch unreachable;
        return std.math.add(u64, whole, partial) catch std.math.maxInt(u64);
    }
    whole -|= (remainder - rest) / hz;
    return whole;
}
