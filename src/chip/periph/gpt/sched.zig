//! When a GPT channel's next overflow is due on the virtual time base
//! (RA8EMU-179, slice RA8EMU-513).
//!
//! The GPT still counts `step_per_tick` (0x4001) per chunk boundary at the
//! undivided clock, and a boundary is `cadence.instructions` CPU0 cycles at
//! the time base's rate. So the PCLKD this model already counts at is that
//! ratio, 16385 counts per 50000 ns, 327.7 MHz. Deriving the rate from the
//! stepping, as agt/sched.zig does for PCLKB, keeps a queued overflow on the
//! boundary the step lands it on. The clock tree slice (RA8EMU-515) is where
//! PCLKD becomes the part's real number.
//!
//! The count itself moves by virtual time too (`tickFor`): a full boundary
//! at PCLKD is exactly the old 0x4001 step. A divided channel counts the
//! true quotient (4096 or 4097 a boundary at /4, averaging 4096.25) instead
//! of the old step nudged odd; the sum over four boundaries is 16385, odd,
//! so the count still walks every value of a power-of-two period.
//!
//! A compare match is due when GTCNT next reaches GTCCRA or GTCCRB
//! (`compareDueAt`, RA8EMU-578), worked out from the same absolute counts
//! `tickFor` uses, so it is exact whatever width the boundaries are.
//!
//! A triangle (GTCR.MD symmetric) turns rather than wraps. Its peak and
//! trough are due where the folded phase mode.zig counts in next
//! reaches the period or a whole cycle (`turnDueAt`).
const std = @import("std");
const gpt = @import("gpt.zig");
const ch = @import("channel.zig");
const clk = @import("clock.zig");
const cmp = @import("compare.zig");
const cadence = @import("../../core/cadence.zig");
const timebase = @import("../time/timebase.zig");

/// The PCLKD rate the per-boundary step stands for.
pub const pclkd_hz: u64 = @as(u64, ch.step_per_tick) * timebase.default_hz / cadence.instructions;

/// The virtual ns channel next overflows at, from `now_ns`: a saw's wrap,
/// or a triangle's peak (both set TCFPO). A stopped channel has nothing due.
pub fn dueAt(channel: ch.Channel, now_ns: u64) ?u64 {
    if (!channel.running()) return null;
    if (channel.shape().symmetric()) return turnDueAt(channel, .peak, now_ns);
    const period = channel.periodOrDefault();
    const in_ns = clk.overflowInNs(channel.cnt, period, channel.source(), pclkd_hz) orelse return null;
    return now_ns + in_ns;
}

/// One boundary of counting by virtual time rather than by a fixed step:
/// each channel moves by the counts its TPCS divider passes between
/// `from_ns` and `to_ns`. Worked out from absolute time, so a boundary a
/// timed event narrowed counts a narrow stretch and nothing is lost to
/// rounding across boundaries. Channel 0 wrapping raises its overflow
/// event, as `Gpt.tick` does.
pub fn tickFor(timer: *gpt.Gpt, from_ns: u64, to_ns: u64) void {
    for (&timer.channels, 0..) |*channel, index| {
        const counts = countsBetween(from_ns, to_ns, channel.source().divider());
        if (channel.advance(counts) != 0 and index == 0) timer.pending = true;
    }
}

/// Counts of a PCLKD / `divider` clock between two virtual times, clamped
/// to the counter's width.
pub fn countsBetween(from_ns: u64, to_ns: u64, divider: u32) u32 {
    const counts = countsAt(to_ns, divider) - countsAt(from_ns, divider);
    return @intCast(@min(counts, std.math.maxInt(u32)));
}

fn countsAt(at_ns: u64, divider: u32) u128 {
    return @as(u128, at_ns) * pclkd_hz / (timebase.ns_per_s * @as(u128, divider));
}

/// The virtual ns GTCNT next reaches compare `side` at, from `now_ns`, in
/// saw and one-shot. Null when the channel is stopped or a triangle, or the
/// compare is never reached.
pub fn compareDueAt(channel: ch.Channel, side: cmp.Which, now_ns: u64) ?u64 {
    if (!channel.running() or channel.shape().symmetric()) return null;
    const counts = compareCounts(channel, side) orelse return null;
    const divider = channel.source().divider();
    return nsAtCount(countsAt(now_ns, divider) + counts, divider);
}

/// Counts from GTCNT to the match. A live compare ahead of the count and
/// inside the period matches this cycle. Otherwise a saw matches after the
/// wrap, against the value GTBER's single buffer hands over at the cycle
/// end, as `Channel.reload` does. A one-shot never comes back round. Zero
/// is disarmed, and a compare above GTPR is never reached by GTCNT.
fn compareCounts(channel: ch.Channel, side: cmp.Which) ?u64 {
    const period = channel.periodOrDefault();
    const cnt = channel.cnt;
    const live = channel.compares.value(side);
    if (live != 0 and live > cnt and live <= period) return live - cnt;
    if (channel.shape().once()) return null;
    const next = if (channel.buffered.single(side)) channel.buffered.value(side) else live;
    if (next == 0 or next > period) return null;
    const to_wrap: u64 = if (cnt <= period) @as(u64, period) - cnt + 1 else 1;
    return to_wrap + next;
}

/// The first virtual ns at which `count` edges of PCLKD / `divider` have
/// passed since time zero: the inverse of `countsAt`, rounded up.
fn nsAtCount(count: u128, divider: u32) ?u64 {
    const num = count * timebase.ns_per_s * @as(u128, divider);
    const ns = (num + pclkd_hz - 1) / pclkd_hz;
    if (ns > std.math.maxInt(u64)) return null;
    return @intCast(ns);
}

/// The two places a triangle turns: the peak sets TCFPO, the trough TCFPU
/// and ends the cycle.
pub const Turn = enum { peak, trough };

/// The virtual ns a running triangle next reaches its peak or its trough,
/// from `now_ns`. Null for a stopped channel or one that is not a triangle.
pub fn turnDueAt(channel: ch.Channel, turn: Turn, now_ns: u64) ?u64 {
    if (!channel.running() or !channel.shape().symmetric()) return null;
    const period: u64 = channel.periodOrDefault();
    const cycle = 2 * period;
    // The same phase gpt_mode.fold counts in: the count on the way up, the
    // cycle less the count on the way down.
    const cnt: u64 = channel.cnt;
    const phase = if (channel.rising) cnt else cycle - @min(cnt, cycle);
    const counts = switch (turn) {
        .peak => if (phase < period) period - phase else period + cycle - phase,
        .trough => cycle - phase % cycle,
    };
    const divider = channel.source().divider();
    return nsAtCount(countsAt(now_ns, divider) + counts, divider);
}
