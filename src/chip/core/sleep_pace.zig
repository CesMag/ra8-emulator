//! How far a stretch may reach while the core sleeps (RA8EMU-185, slice 1).
//!
//! A core in WFI or WFE with nothing to wake it ends its stretch at once
//! (src/chip/core/cpu/exception/sleep.zig), and the board then charges the whole
//! stretch to the clocks. What it still pays is a boundary every
//! `cadence.instructions`: fifty microseconds at a gigahertz, so a firmware
//! that sleeps a millisecond between SysTick ticks crosses twenty boundaries
//! to get there, and one that sleeps a second on an RTC alarm crosses twenty
//! thousand. Nothing can wake it before the nearest scheduled event, so the
//! stretch may run straight to that event instead.
//!
//! This is the arithmetic only. Who reports the core asleep and which events
//! count is the caller's: the SysTick edge and the board's event queue are
//! the two known today. An edge of zero is no edge. With no edge known, or
//! the core awake, the width is left as it was. It only ever widens, so a
//! narrower pace chosen elsewhere still has the final say when it applies
//! after this. It widens by whole stretches (RA8EMU-185, slice 4), so a run
//! with the skip crosses the same boundary grid as one without and its
//! output is the same.
const std = @import("std");
const Cpu = @import("cpu/cpu.zig").Cpu;

/// Whether the core sleeps with nothing that could wake it at the start of
/// the next stretch. Unlike `sleep.wakes` it changes nothing: a WFE's event
/// register is read, never taken. Anything pending, masked or not, counts
/// as a reason to keep the normal width.
pub fn still(cpu: *Cpu) bool {
    const why = cpu.waiting orelse return false;
    if (why == .event and cpu.event) return false;
    const from = cpu.source orelse return false;
    const pending = from.winner(cpu.bus) catch return false;
    return pending == null;
}

/// Whether the core spins on a loop whose trips change nothing
/// (src/chip/core/cpu/park.zig, fixed_trip.zig) with nothing pending, so
/// only an interrupt the board raises at a boundary can move it, just as
/// for a core asleep in WFI (RA8EMU-1120). A fetch guard turns the skip
/// off, so the note it left is stale under one.
pub fn parked(cpu: *Cpu) bool {
    if (!cpu.trip.parked or cpu.waiting != null or cpu.fetch_guard != null) return false;
    const from = cpu.source orelse return false;
    const pending = from.winner(cpu.bus) catch return false;
    return pending == null;
}

/// The width the next stretch gets. `normal` is what the run would use
/// otherwise; `edges` are cycles until each known next event.
pub fn width(normal: u32, asleep: bool, edges: []const u64) u32 {
    if (!asleep) return normal;
    var nearest: u64 = 0;
    for (edges) |edge| {
        if (edge == 0) continue;
        if (nearest == 0 or edge < nearest) nearest = edge;
    }
    if (nearest <= normal) return normal;
    // Whole stretches only: the boundary lands where an unskipped run's
    // would, the first one at or after the edge, so skipping changes speed
    // and nothing else.
    const most = std.math.maxInt(u32) / normal;
    const stretches = @min(std.math.divCeil(u64, nearest, normal) catch unreachable, most);
    return @intCast(stretches * normal);
}
