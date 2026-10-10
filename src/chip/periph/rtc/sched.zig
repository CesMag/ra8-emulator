//! When the RTC next needs a boundary on the virtual time base (RA8EMU-182,
//! slice 3).
//!
//! A virtual-time RTC owes its seconds at whole-second edges of the virtual
//! nanoseconds it has run. The alarm compare and the periodic event are both
//! evaluated when a second lands, so the clock queues the next second edge
//! whenever either is enabled, and the boundary that closes on it evaluates
//! the alarm at the virtual time it matched. Queuing the edge rather than
//! working out how many seconds away the match is keeps this one division
//! per boundary; a far alarm costs one event a second, which idle
//! fast-forward (RA8EMU-185) skips through. A geared clock and a stopped one
//! queue nothing, which is what keeps the corpus unchanged.
const rtc = @import("rtc.zig");
const rtc_pace = @import("pace.zig");
const event_queue = @import("../time/event_queue.zig");

/// The queue id the RTC's second edge is scheduled under.
pub const queue_id: u16 = 0x0C00;

/// The virtual ns of the clock's next second edge, from `now_ns`, or null
/// when nothing would be evaluated there.
pub fn dueAt(unit: *const rtc.Rtc, now_ns: u64) ?u64 {
    if (unit.pace.mode != .virtual or !unit.running()) return null;
    if (!unit.armed() and unit.reg[rtc.off.rcr1] & rtc.control.pie == 0) return null;
    const into = unit.pace.run_ns % rtc_pace.ns_per_second;
    return now_ns + (rtc_pace.ns_per_second - into);
}

/// Replace whatever second edge the clock had queued. Called at every
/// boundary, so a clock firmware stopped, restarted or re-armed picks the
/// right edge without hooking the register writes.
pub fn arm(unit: *const rtc.Rtc, queue: *event_queue.EventQueue, now_ns: u64) event_queue.Error!void {
    _ = queue.cancel(queue_id);
    const at = dueAt(unit, now_ns) orelse return;
    try queue.schedule(at, queue_id);
}
