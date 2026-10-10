//! When an AGT channel's next underflow is due on the virtual time base
//! (RA8EMU-179, slice RA8EMU-512).
//!
//! The AGT still counts `agt.step_per_tick` per chunk boundary, and a
//! boundary is `cadence.instructions` CPU0 cycles at the time base's rate.
//! So the PCLKB this model already counts at is that ratio, 2048 counts per
//! 50000 ns, 40.96 MHz. Deriving the rate from the stepping instead of
//! taking the part's real PCLKB is what keeps a queued underflow on the very
//! boundary the step lands it on, so moving the AGT onto the event queue
//! does not shift one line of the corpus. The clock tree slice (RA8EMU-515)
//! is where PCLKB becomes the part's real number.
const std = @import("std");
const agt = @import("agt.zig");
const clk = @import("clock.zig");
const cadence = @import("../../core/cadence.zig");
const timebase = @import("../time/timebase.zig");
const event_queue = @import("../time/event_queue.zig");

/// The PCLKB rate the per-boundary step stands for.
pub const pclkb_hz: u64 = @as(u64, agt.step_per_tick) * timebase.default_hz / cadence.instructions;

/// The virtual ns channel `index` next underflows at, from `now_ns`. A
/// stopped channel and a cascaded one (it counts AGT0, not a clock) have
/// nothing due.
pub fn dueAt(channel: agt.Channel, index: usize, now_ns: u64) ?u64 {
    if (!channel.running()) return null;
    const in_ns = clk.underflowInNs(channel.counter, channel.source(index), pclkb_hz) orelse return null;
    return now_ns + in_ns;
}

/// The queue id channel `index` schedules its underflow under.
pub fn queueId(index: usize) u16 {
    return queue_id_base + @as(u16, @intCast(index));
}

pub const queue_id_base: u16 = 0x0A00;

/// Put each running channel's next underflow on `queue`, dropping whatever
/// it had there first. Called at every boundary, so an underflow that just
/// fired, a channel that stopped and a counter or reload firmware rewrote
/// all re-arm without hooking the register writes: the next stretch is
/// sized after this has run.
pub fn arm(timer: *const agt.Agt, queue: *event_queue.EventQueue, now_ns: u64) event_queue.Error!void {
    for (timer.channels, 0..) |channel, index| {
        _ = queue.cancel(queueId(index));
        const at = dueAt(channel, index, now_ns) orelse continue;
        try queue.schedule(at, queueId(index));
    }
}

/// One boundary of counting by virtual time rather than by a fixed step:
/// each channel moves by the PCLKB counts its divider passes between
/// `from_ns` and `to_ns`. Worked out from absolute time, so a boundary a
/// timed event narrowed counts a narrow stretch and nothing is lost to
/// rounding across boundaries. AGT0's underflow still carries into a
/// cascaded AGT1, in index order, as `Agt.tick` does.
pub fn tickFor(timer: *agt.Agt, from_ns: u64, to_ns: u64) void {
    var carried: u16 = 0;
    for (&timer.channels, 0..) |*channel, index| {
        const source = channel.source(index);
        const underflowed = if (source.cascaded())
            channel.tickCascade(carried)
        else
            channel.advance(countsBetween(from_ns, to_ns, source.divider()));
        if (index == clk.cascade.low and underflowed) carried += 1;
        if (index == 0 and underflowed) timer.pending +%= 1;
    }
}

/// Counts of a PCLKB / `divider` clock between two virtual times. Clamped
/// to the counter's width; a boundary that long wraps the count anyway.
pub fn countsBetween(from_ns: u64, to_ns: u64, divider: u16) u16 {
    const counts = countsAt(to_ns, divider) - countsAt(from_ns, divider);
    return @intCast(@min(counts, std.math.maxInt(u16)));
}

fn countsAt(at_ns: u64, divider: u16) u128 {
    return @as(u128, at_ns) * pclkb_hz / (timebase.ns_per_s * @as(u128, divider));
}
